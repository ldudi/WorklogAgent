import Foundation

public struct ScreenshotSelectionSettings: Sendable {
    public var dynamic: Bool
    public var minimum: Int
    public var maximum: Int
    public static let safetyMaximum = 12

    public init(dynamic: Bool = true, minimum: Int = 1, maximum: Int = 12) {
        self.dynamic = dynamic
        self.maximum = min(Self.safetyMaximum, max(0, maximum))
        self.minimum = min(self.maximum, max(0, minimum))
    }

    /// Missing keys migrate by default; existing vision preference is owned separately.
    public init(defaults: UserDefaults) {
        self.init(dynamic: defaults.object(forKey: "dynamicScreenshots") as? Bool ?? true,
                  minimum: defaults.object(forKey: "minimumScreenshots") as? Int ?? 1,
                  maximum: defaults.object(forKey: "maximumScreenshots") as? Int ?? 12)
    }
    public func save(to defaults: UserDefaults) {
        let safe = normalized
        defaults.set(safe.dynamic, forKey: "dynamicScreenshots")
        defaults.set(safe.minimum, forKey: "minimumScreenshots")
        defaults.set(safe.maximum, forKey: "maximumScreenshots")
    }
    var normalized: Self { Self(dynamic: dynamic, minimum: minimum, maximum: maximum) }
}

/// These signals prioritize evidence, never assert that an outcome actually occurred.
enum OutcomeSignals {
    static let errors: Set<String> = ["error", "failed", "failure", "exception", "fatal", "crash"]
    static let results: Set<String> = ["passed", "success", "succeeded", "deployed", "completed", "merged", "submitted"]
    static func words(_ text: String) -> Set<String> { OCRDeduplicator().tokenSet(text) }
    static func signature(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: \.isNewline).filter {
            !words(String($0)).intersection(errors.union(results).union(["warning"])).isEmpty || $0.contains("build complete")
        }.map(String.init))
    }
    static func boost(_ text: String) -> (Double, String?) {
        let tokens = words(text)
        if !tokens.intersection(errors).isEmpty { return (0.45, "possible error/failure") }
        if !tokens.intersection(results).isEmpty || text.lowercased().contains("build complete") { return (0.50, "possible result/success") }
        if tokens.contains("warning") { return (0.25, "possible warning") }
        return (0, nil)
    }
}

public struct VisualSelectionItem: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let display: String
    public let screenshotReference: String
    public let frameID: String
    public let clusterID: String
    public let score: Double
    public let reasons: [String]
}

public struct VisualSelectionMetadata: Codable, Sendable, Equatable {
    public var policyVersion = 2
    public var candidateScreenshotCount: Int
    public var eligibleScreenshotCount: Int
    public var distinctClusterCount: Int
    public var highValueOutcomeCount: Int
    public var dynamicBudget: Int
    public var selectionReason: String
    public var rejectedNearDuplicates: Int
    public var rejectedLowValue: Int
    public var selected: [VisualSelectionItem]
    public var visionEnabled: Bool
    public var estimatedImagePayloadBytes: Int
    public var encodedImagePayloadBytes = 0
    public var requestedImageCount = 0
    public var recognizedImageCount = 0
    public var visionInferenceSeconds: Double = 0
    public var selectedScreenshotCount: Int { selected.count }

    public var diagnostics: String {
        """
        Vision selection (policy v\(policyVersion))
        Raw screenshots: \(candidateScreenshotCount)
        Eligible screenshots: \(eligibleScreenshotCount)
        Visual/activity clusters: \(distinctClusterCount)
        High-value outcome states: \(highValueOutcomeCount)
        Displays represented: \(Set(selected.map(\.display)).count)
        Dynamic budget: \(dynamicBudget) (\(selectionReason))
        Selected screenshots: \(selectedScreenshotCount)
        Vision enabled: \(visionEnabled)
        Estimated image payload bytes (source-file base64 estimate; before resize): \(estimatedImagePayloadBytes)
        Encoded image payload bytes: \(encodedImagePayloadBytes)
        Requested/recognized images: \(requestedImageCount)/\(recognizedImageCount)
        Vision inference seconds: \(String(format: "%.2f", visionInferenceSeconds))
        Selection:
        \(selected.map { "\(WorklogWriter.time($0.timestamp)) | \(SecretRedactor().redact($0.display)) | score \(String(format: "%.2f", $0.score)) | \($0.reasons.joined(separator: ", ")) | cluster \($0.clusterID)" }.joined(separator: "\n"))
        Rejected near-duplicates: \(rejectedNearDuplicates)
        Rejected low-value frames: \(rejectedLowValue)
        """
    }
}

struct VisualCandidate {
    let image: ScreenshotEvidence
    let text: String
    let stateID: String
    let context: String
    let score: Double
    let reasons: [String]
}

struct VisualSelection {
    var selected: [VisualCandidate]
    var metadata: VisualSelectionMetadata
}

/// Reuses cleaned OCR and OCRDeduplicator's state boundaries/token similarity.
/// Sampling does not depend on the model, input ordering, or wall-clock time.
struct VisualEvidenceSampler {
    func select(images: [ScreenshotEvidence], observations: [OCRObservation], start: Date, end: Date,
                settings: ScreenshotSelectionSettings = .init(), visionEnabled: Bool = true,
                projects: ProjectConfiguration = .init()) -> VisualSelection {
        let settings = settings.normalized
        let strictIDs = Set(ActivityPreprocessor().clean(observations).map(\.id))
        let cleaned = ActivityPreprocessor().clean(observations, tolerateArtifacts: true)
        let states = OCRDeduplicator().deduplicate(cleaned)
        let byFrame = Dictionary(grouping: cleaned, by: \.frameID)
        let rawByFrame = Dictionary(grouping: observations, by: \.frameID)
        let statesByDisplay = Dictionary(grouping: states) { $0.displayName ?? "Unknown display" }
        let ordered = images.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.id < $1.id
        }
        var eligible: [VisualCandidate] = []
        for image in ordered {
            let row = byFrame[image.id]?.first { ($0.displayName ?? "Unknown display") == image.displayName }
            let text = row?.text ?? ""
            let tokens = OutcomeSignals.words(text)
            let outcome = OutcomeSignals.boost(text)
            guard tokens.count >= 3 || outcome.0 > 0 else { continue }
            let state = statesByDisplay[image.displayName]?.first {
                $0.startedAt <= image.startedAt && $0.observedThrough >= image.startedAt
            }
            let stateID = state?.id ?? row?.id ?? image.id
            var score = 0.25 + min(0.15, Double(tokens.count) / 200)
            var reasons = ["useful content"]
            if let row, !strictIDs.contains(row.id) {
                score -= 0.12; reasons.append("partial OCR; visual context")
            }
            if state?.frameID == image.id { score += 0.15; reasons.append("activity start/transition") }
            score += outcome.0
            if let reason = outcome.1 { reasons.append(reason) }
            if image.id == ordered.last?.id { score += 0.08; reasons.append("final state") }
            if image.id == ordered.first?.id { score += 0.10; reasons.append("interval beginning") }
            if let previous = eligible.last(where: { $0.image.displayName == image.displayName }),
               image.startedAt.timeIntervalSince(previous.image.startedAt) >= 1800 {
                score += 0.05; reasons.append("long evidence gap")
            }
            // Generic player chrome is weak evidence; changing pixels alone must not fill the budget.
            if tokens.intersection(["play", "pause", "playlist", "autoplay", "volume", "subscribe"]).count >= 2 && outcome.0 == 0 {
                score -= 0.20; reasons.append("playback/background context")
            }
            let project = projects.infer(from: text)?.id ?? ""
            let domain = text.range(of: #"(?i)\b(?:(?:https?://|www\.)(?:[a-z0-9-]+\.)+[a-z]{2,}|[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|org|net|edu|gov|io|dev|app|ai|co|info|biz|me|tv|tech|cloud|site|online))\b"#, options: .regularExpression).map {
                String(text[$0]).lowercased().replacingOccurrences(of: #"^(?:https?://)?(?:www\.)?"#, with: "", options: .regularExpression)
            } ?? ""
            eligible.append(VisualCandidate(image: image, text: text, stateID: stateID,
                context: project + "|" + domain + "|" + applicationContext(rawByFrame[image.id]?.first(where: { ($0.displayName ?? "Unknown display") == image.displayName })?.text ?? ""), score: score, reasons: reasons))
        }
        // Preserve endpoints of usable evidence, even if the raw interval endpoints are noisy.
        let eligibleByDisplay = Dictionary(grouping: eligible) { $0.image.displayName }
        eligible = eligible.map { candidate in
            var score = candidate.score
            var reasons = candidate.reasons
            let rows = eligibleByDisplay[candidate.image.displayName] ?? []
            if candidate.image.id == rows.first?.image.id && !reasons.contains("interval beginning") {
                score += 0.10; reasons.append("first useful display state")
            }
            if candidate.image.id == rows.last?.image.id && !reasons.contains("final state") {
                score += 0.08; reasons.append("final useful display state")
            }
            return VisualCandidate(image: candidate.image, text: candidate.text, stateID: candidate.stateID,
                context: candidate.context, score: score, reasons: reasons)
        }
        // With no legible OCR, retain one valid visual fallback. Do not add noisy secondary screens
        // when useful OCR-backed visual evidence exists on another display.
        if eligible.isEmpty, let image = ordered.first(where: { $0.perceptualHash.count == 8 }) {
            eligible = [VisualCandidate(image: image, text: "", stateID: image.id, context: "", score: 0.20, reasons: ["visual fallback; no useful OCR"])]
        }
        var clusters: [[VisualCandidate]] = []
        for candidate in eligible {
            if let index = clusters.firstIndex(where: { group in
                guard let first = group.first else { return false }
                return equivalent(candidate, first)
            }) { clusters[index].append(candidate) }
            else { clusters.append([candidate]) }
        }
        let representatives = clusters.compactMap { group in
            group.sorted(by: ranked).first
        }
        let outcomes = representatives.filter { OutcomeSignals.boost($0.text).0 > 0 }.count
        let count = representatives.count
        // Square-root complexity grows sublinearly; time contributes at most one slot, only
        // when at least four distinct states actually exist. Minimum is a preference, not padding.
        let durationBonus = count >= 4 && end.timeIntervalSince(start) >= 3 * 3600 ? 1 : 0
        let computed = count == 0 ? 0 : Int(ceil(2 * sqrt(Double(count)))) + min(2, outcomes) + durationBonus
        let budget = count == 0 ? 0 : min(settings.maximum, max(settings.minimum, settings.dynamic ? computed : settings.maximum))
        var pool: [VisualCandidate] = []
        var crossDisplayDuplicates = 0
        // Resolve duplicates by base importance before diversity bonuses can reorder them.
        for candidate in representatives.sorted(by: ranked) {
            if pool.contains(where: { equivalent(candidate, $0, crossDisplay: true) }) {
                crossDisplayDuplicates += 1
            } else { pool.append(candidate) }
        }
        var chosen: [VisualCandidate] = []
        if visionEnabled {
            while chosen.count < budget && !pool.isEmpty {
                let displays = Set(chosen.map { $0.image.displayName })
                let contexts = Set(chosen.map(\.context))
                pool.sort {
                    let lhs = $0.score + (displays.contains($0.image.displayName) ? 0 : 0.12) + (contexts.contains($0.context) ? 0 : 0.10)
                    let rhs = $1.score + (displays.contains($1.image.displayName) ? 0 : 0.12) + (contexts.contains($1.context) ? 0 : 0.10)
                    return lhs == rhs ? ranked($0, $1) : lhs > rhs
                }
                let next = pool.removeFirst()
                // Recheck duplicates across displays immediately before constructing payloads.
                if chosen.contains(where: { equivalent(next, $0, crossDisplay: true) }) { continue }
                chosen.append(next)
            }
        }
        chosen.sort { $0.image.startedAt == $1.image.startedAt ? $0.image.id < $1.image.id : $0.image.startedAt < $1.image.startedAt }
        let items = chosen.map { candidate in
            VisualSelectionItem(timestamp: candidate.image.startedAt, display: SecretRedactor().redact(candidate.image.displayName),
                screenshotReference: candidate.image.url.path, frameID: candidate.image.id,
                clusterID: stableID("visual-v2:\(candidate.image.displayName):\(candidate.stateID)"),
                score: candidate.score, reasons: candidate.reasons)
        }
        let estimate = chosen.reduce(0) { result, item in
            let size = (try? item.image.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return result + ((size + 2) / 3) * 4
        }
        return VisualSelection(selected: chosen, metadata: VisualSelectionMetadata(candidateScreenshotCount: images.count,
            eligibleScreenshotCount: eligible.count, distinctClusterCount: count, highValueOutcomeCount: outcomes,
            dynamicBudget: visionEnabled ? budget : 0, selectionReason: settings.dynamic ? "ceil(2√clusters) + min(2,outcomes) + bounded duration; min/max clamped" : "configured maximum; distinct evidence only",
            rejectedNearDuplicates: eligible.count - count + crossDisplayDuplicates,
            rejectedLowValue: images.count - eligible.count, selected: items, visionEnabled: visionEnabled,
            estimatedImagePayloadBytes: estimate))
    }

    private func applicationContext(_ text: String) -> String {
        // Menu labels are often removed as persistent chrome. Keep only an app-name
        // fingerprint from an explicit "<app> File Edit" menu sequence, never window text.
        let safe = SecretRedactor().redact(text)
        guard let range = safe.range(of: #"(?m)^[\p{L}\p{N} .+\-]{2,60}[ \t]+File[ \t]+Edit\b"#, options: .regularExpression) else { return "" }
        let line = String(safe[range])
        guard let boundary = line.range(of: #"[ \t]+File[ \t]+Edit$"#, options: .regularExpression) else { return "" }
        return stableID(String(line[..<boundary.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased())
    }

    private func ranked(_ lhs: VisualCandidate, _ rhs: VisualCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.image.startedAt != rhs.image.startedAt { return lhs.image.startedAt < rhs.image.startedAt }
        if lhs.image.displayName != rhs.image.displayName { return lhs.image.displayName < rhs.image.displayName }
        return lhs.image.id < rhs.image.id
    }
    private func equivalent(_ lhs: VisualCandidate, _ rhs: VisualCandidate, crossDisplay: Bool = false) -> Bool {
        guard crossDisplay || lhs.image.displayName == rhs.image.displayName else { return false }
        guard lhs.context == rhs.context, OutcomeSignals.signature(lhs.text) == OutcomeSignals.signature(rhs.text) else { return false }
        let dedup = OCRDeduplicator()
        let similarity = dedup.jaccard(dedup.tokenSet(lhs.text), dedup.tokenSet(rhs.text))
        let partial = lhs.reasons.contains("partial OCR; visual context") || rhs.reasons.contains("partial OCR; visual context")
        // OCR artifacts fluctuate even on a static screen. Require stronger text agreement
        // for clean OCR, but let JustNow's visual hash corroborate partial OCR.
        if !lhs.text.isEmpty && similarity >= (partial ? 0.65 : dedup.similarityThreshold) { return true }
        let a = lhs.image.perceptualHash, b = rhs.image.perceptualHash
        return a.count == 8 && b.count == 8 && (similarity >= 0.70 || partial) &&
            zip(a, b).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount } <= 6
    }
}

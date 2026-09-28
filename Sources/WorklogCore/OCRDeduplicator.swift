import Foundation

public struct OCRDeduplicator {
    public var similarityThreshold: Double
    public var minimumTextLength: Int

    public init(similarityThreshold: Double = 0.90, minimumTextLength: Int = 12) {
        self.similarityThreshold = similarityThreshold
        self.minimumTextLength = minimumTextLength
    }

    public func deduplicate(_ observations: [OCRObservation]) -> [OCRObservation] {
        var result: [OCRObservation] = []
        var previousTokensByDisplay: [String: Set<String>] = [:]

        for observation in observations.sorted(by: { $0.startedAt < $1.startedAt }) {
            let normalized = normalize(observation.text)
            guard normalized.count >= minimumTextLength else { continue }
            let tokens = tokenSet(normalized)
            guard !tokens.isEmpty else { continue }

            let displayKey = observation.displayName ?? "__unknown_display__"
            if let previousTokens = previousTokensByDisplay[displayKey],
               jaccard(previousTokens, tokens) >= similarityThreshold,
               let index = result.lastIndex(where: { ($0.displayName ?? "__unknown_display__") == displayKey }),
               observation.startedAt.timeIntervalSince(result[index].observedThrough) <= 120,
               !hasNewOutcome(normalized, comparedTo: result[index].text) {
                let previous = result[index]
                result[index] = OCRObservation(
                    id: previous.id, frameID: previous.frameID, startedAt: previous.startedAt,
                    observedThrough: max(previous.observedThrough, observation.observedThrough),
                    observationCount: previous.observationCount + observation.observationCount,
                    displayName: previous.displayName, text: previous.text
                )
                continue
            }

            result.append(
                OCRObservation(
                    id: observation.id,
                    frameID: observation.frameID,
                    startedAt: observation.startedAt,
                    observedThrough: observation.observedThrough,
                    observationCount: observation.observationCount,
                    displayName: observation.displayName,
                    text: normalized
                )
            )
            previousTokensByDisplay[displayKey] = tokens
        }
        return result
    }

    private func hasNewOutcome(_ text: String, comparedTo previous: String) -> Bool {
        let oldLines = Set(previous.lowercased().split(whereSeparator: \.isNewline).map(String.init))
        return text.lowercased().split(whereSeparator: \.isNewline).contains { line in
            ["passed", "failed", "error:", "build complete"].contains(where: line.contains) && !oldLines.contains(String(line))
        }
    }

    private func normalize(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\u{0000}", with: "")
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private func tokenSet(_ text: String) -> Set<String> {
        let tokens = text.lowercased().split { character in
            !character.isLetter && !character.isNumber && character != "_"
        }
        return Set(tokens.filter { $0.count > 1 }.map(String.init))
    }

    private func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        guard union > 0 else { return 1 }
        return Double(intersection) / Double(union)
    }
}

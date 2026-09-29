import Foundation

/// Lightweight filtering of screen evidence. Redaction precedes every transformation.
public struct ActivityPreprocessor {
    public init() {}

    public func clean(_ observations: [OCRObservation], tolerateArtifacts: Bool = false) -> [OCRObservation] {
        let normalized = observations.sorted { $0.startedAt < $1.startedAt }.map { observation in
            let text = SecretRedactor().redact(observation.text).precomposedStringWithCompatibilityMapping
            var seen = Set<String>()
            let lines = text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
                // Vision needs partial context even when OCR contains unsupported icon glyphs.
                // Canonical text preprocessing remains strict; both paths use the same quality rules.
                let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: " .,:;!?/_-+={}[]()<>@#%&*|\\\"'`~$"))
                let source = tolerateArtifacts ? String(String.UnicodeScalarView(raw.unicodeScalars.map {
                    allowed.contains($0) ? $0 : UnicodeScalar(32)
                })) : String(raw)
                let line = source.replacingOccurrences(of: "\u{0000}", with: "")
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard isUseful(line), seen.insert(line.lowercased()).inserted else { return nil }
                return line
            }
            return (observation, lines)
        }
        let byDisplay = Dictionary(grouping: normalized) { $0.0.displayName ?? "Unknown display" }
        var persistentByDisplay: [String: Set<String>] = [:]
        for (display, rows) in byDisplay where rows.count >= 5 {
            var frequencies: [String: Int] = [:]
            for (_, lines) in rows {
                for line in lines { frequencies[line.lowercased(), default: 0] += 1 }
            }
            persistentByDisplay[display] = Set(frequencies.compactMap { line, count in
                Double(count) / Double(rows.count) >= 0.8 && isChrome(line) ? line : nil
            })
        }
        return normalized.compactMap { observation, lines in
            let persistent = persistentByDisplay[observation.displayName ?? "Unknown display"] ?? []
            let retained = lines.filter { !persistent.contains($0.lowercased()) }
            guard !retained.isEmpty else { return nil }
            let ranked = retained.enumerated().sorted {
                let lhs = evidencePriority($0.element), rhs = evidencePriority($1.element)
                return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
            }.prefix(40).map(\.element)
            return OCRObservation(
                id: observation.id, frameID: observation.frameID,
                startedAt: observation.startedAt, observedThrough: observation.observedThrough,
                observationCount: observation.observationCount, displayName: observation.displayName,
                text: ranked.joined(separator: "\n")
            )
        }
    }

    private func isUseful(_ line: String) -> Bool {
        guard line.count >= 3, line.filter({ $0.isLetter }).count >= 3 else { return false }
        let allowed = CharacterSet(charactersIn: " .,:;!?/_-+={}[]()<>@#%&*|\\\"'`~$\t")
        let artifacts = line.unicodeScalars.filter {
            !CharacterSet.alphanumerics.contains($0) && !allowed.contains($0)
        }.count
        guard Double(artifacts) / Double(line.count) < 0.025 else { return false }
        guard line.range(of: #"(.)\1{5,}"#, options: .regularExpression) == nil else { return false }
        let words = line.split(whereSeparator: \.isWhitespace)
        let useful = words.filter { word in
            let alpha = word.filter { $0.isLetter }
            guard alpha.count >= 2 else { return false }
            if word.count > 60 && !word.contains("://") { return false }
            return alpha.contains { "aeiouAEIOU".contains($0) } || word.contains("_") || word.contains(".") || alpha.allSatisfy(\.isUppercase)
        }.count
        return Double(useful) / Double(max(1, words.count)) >= 0.45
    }

    private func isChrome(_ line: String) -> Bool {
        let words = Set(line.split { !$0.isLetter }.map(String.init))
        let menus: Set<String> = ["file", "edit", "view", "window", "help", "history", "bookmarks", "tools"]
        return words.intersection(menus).count >= 3 ||
            ["home", "subscriptions", "library", "subscribe", "sign in", "search", "share", "downloads"].contains(line)
    }

    private func evidencePriority(_ line: String) -> Int {
        let lower = line.lowercased()
        if ["swift ", "git ", "error:", "tests passed", "build complete", ".swift", "failed", "ollama", "worklogagent", "xcode", "terminal"].contains(where: lower.contains) { return 2 }
        if ["youtube", "http", "research", "video"].contains(where: lower.contains) { return 1 }
        return 0
    }
}

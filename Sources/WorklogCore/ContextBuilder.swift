import Foundation

public struct ContextBuilder {
    public var maxCharacters: Int
    public var maxCharactersPerObservation: Int

    public init(maxCharacters: Int = 12_000, maxCharactersPerObservation: Int = 900) {
        self.maxCharacters = maxCharacters
        self.maxCharactersPerObservation = maxCharactersPerObservation
    }

    public func build(from observations: [OCRObservation], redactor: SecretRedactor = SecretRedactor()) -> String {
        let limit = max(0, maxCharacters)
        guard limit > 0, !observations.isEmpty else { return "" }
        let groups = Dictionary(grouping: observations) { $0.displayName ?? "Unknown display" }
        let slotsPerDisplay = max(1, 24 / groups.count)
        let selected = groups.keys.sorted().flatMap { key -> [OCRObservation] in
            let rows = (groups[key] ?? []).sorted { $0.startedAt < $1.startedAt }
            return evenlySpaced(rows, limit: slotsPerDisplay)
        }.sorted { $0.startedAt < $1.startedAt }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let perBlock = max(1, (limit - max(0, selected.count - 1) * 2) / max(1, selected.count))
        return String(selected.map { observation in
            let display = redactor.redact(observation.displayName ?? "Unknown display")
            let header = "[\(formatter.string(from: observation.startedAt))–\(formatter.string(from: observation.observedThrough)) | \(display)]\n"
            let textLimit = max(0, min(maxCharactersPerObservation, perBlock - header.count))
            return String((header + String(redactor.redact(observation.text).prefix(textLimit))).prefix(perBlock))
        }.joined(separator: "\n\n").prefix(limit))
    }
}

func evenlySpaced<T>(_ rows: [T], limit: Int) -> [T] {
    guard limit > 0 else { return [] }
    guard rows.count > limit else { return rows }
    guard limit > 1 else { return [rows[rows.count - 1]] }
    return (0..<limit).map { rows[$0 * (rows.count - 1) / (limit - 1)] }
}

/// Reserve space for every interval rather than dropping the beginning of the day.
public struct DailyContextBuilder {
    public var maxCharacters: Int
    public init(maxCharacters: Int = 20_000) { self.maxCharacters = maxCharacters }

    public func build(from markdown: String) -> String {
        let limit = max(0, maxCharacters)
        guard limit > 0 else { return "" }
        let entries = markdown.components(separatedBy: "\n## ").dropFirst().map { "## " + $0 }
        guard !entries.isEmpty else { return String(markdown.prefix(limit)) }
        let perEntry = max(0, (limit - (entries.count - 1) * 2) / entries.count)
        return String(entries.map { String($0.prefix(perEntry)) }.joined(separator: "\n\n").prefix(limit))
    }
}

import Foundation

public struct LegacyImportResult: Sendable {
    public var importedIntervals: Int = 0
    public var importedSeconds: Double = 0
    public var skippedEntries: Int = 0
}
/// Legacy prose is never treated as screenshot-level evidence. Overlapping ranges contribute only uncovered time.
public struct LegacyMarkdownImporter {
    public init() {}
    public func importDirectory(_ directory: URL, into store: ActivityStore) async throws -> LegacyImportResult {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil }.sorted { $0.path < $1.path }
        var result = LegacyImportResult()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("<!-- WORKLOG_SQLITE_PROJECTION v1 -->") { continue }
            let day = String(file.deletingPathExtension().lastPathComponent)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
            let sections = WorklogWriter().intervalEntries(in: text).components(separatedBy: "\n## ").dropFirst()
            var candidates: [(start: Date, end: Date, title: String, summary: String)] = []
            for section in sections {
                let header = section.components(separatedBy: "\n").first ?? ""
                guard header.range(of: #"^\d{2}:\d{2}[–-]\d{2}:\d{2}$"#, options: .regularExpression) != nil,
                      section.contains("### Activity"), !section.localizedCaseInsensitiveContains("could you please clarify") else { result.skippedEntries += 1; continue }
                let times = header.components(separatedBy: CharacterSet(charactersIn: "–-"))
                guard times.count == 2, let start = formatter.date(from: day + " " + times[0]), var end = formatter.date(from: day + " " + times[1]) else { result.skippedEntries += 1; continue }
                if end < start { guard let next = Calendar.current.date(byAdding: .day, value: 1, to: end) else { continue }; end = next }
                guard end > start else { result.skippedEntries += 1; continue }
                let body = section.components(separatedBy: "### Activity").dropFirst().joined(separator: "### Activity")
                let activity = body.components(separatedBy: "\n### ").first ?? ""
                let bullets = activity.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
                guard let title = bullets.first else { result.skippedEntries += 1; continue }
                candidates.append((start, end, String(SecretRedactor().redact(title).prefix(240)), String(SecretRedactor().redact(bullets.joined(separator: "; ")).prefix(1200))))
            }
            for candidate in candidates.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
                let gaps = try await store.unprocessedRanges(from: candidate.start, to: candidate.end)
                if gaps.isEmpty { result.skippedEntries += 1 }
                for gap in gaps {
                    var record = ActivityReconstruction().fallback(start: gap.start, end: gap.end, evidenceIDs: [])
                    record.title = candidate.title; record.summary = candidate.summary
                    record.source = .legacyMarkdown; record.confidence = 0.35
                    // Purpose and split timing cannot be reconstructed reliably from legacy prose alone.
                    try await store.persist(start: gap.start, end: gap.end, records: [record], evidence: [])
                    result.importedIntervals += 1; result.importedSeconds += gap.duration
                }
            }
        }
        return result
    }
}

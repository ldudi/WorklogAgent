import Foundation

public struct WorklogWriter {
    static let dailyMarker = "<!-- WORKLOG_AGENT_DAILY_SUMMARY -->"
    static let dailyEndMarker = "<!-- WORKLOG_AGENT_DAILY_SUMMARY_END -->"
    public let outputDirectory: URL

    public init(outputDirectory: URL = WorklogConfiguration.defaultOutputDirectory) {
        self.outputDirectory = outputDirectory
    }

    public func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw WorklogError.invalidOutputDirectory(outputDirectory)
        }
    }

    public func worklogURL(for date: Date) -> URL {
        outputDirectory.appendingPathComponent(Self.dayKey(date) + ".md")
    }

    /// Probe both folder creation and append access without changing an existing worklog.
    public func validateWriteAccess(for date: Date) throws {
        let url = worklogURL(for: date)
        let probe = outputDirectory.appendingPathComponent(".worklog-write-check-\(UUID().uuidString)")
        do {
            try ensureDirectory()
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.close()
            }
            try Data().write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch {
            throw WorklogError.outputNotWritable(url)
        }
    }

    @discardableResult
    public func appendIntervalSummary(_ markdown: String, start: Date, end: Date) throws -> URL {
        try ensureDirectory()
        let url = worklogURL(for: start)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let header = exists ? "" : "# Worklog — \(Self.displayDate(start))\n\n"
        let intervalHeader = "## \(Self.time(start))–\(Self.time(end))\n\n"
        let block = header + intervalHeader + markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n\n"

        if exists {
            let current = try String(contentsOf: url, encoding: .utf8)
            if let marker = current.range(of: Self.dailyMarker) {
                // Keep all interval entries before the generated daily section.
                let updated = String(current[..<marker.lowerBound]) + block + String(current[marker.lowerBound...])
                try updated.write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = block.data(using: .utf8) { try handle.write(contentsOf: data) }
        } else {
            try block.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    @discardableResult
    public func appendDailySummary(_ markdown: String, for date: Date) throws -> URL {
        try ensureDirectory()
        let url = worklogURL(for: date)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorklogError.invalidOutputDirectory(url)
        }
        let current = try String(contentsOf: url, encoding: .utf8)
        let block = "\n\(Self.dailyMarker)\n\n" + markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n\(Self.dailyEndMarker)\n"
        let updated = intervalEntries(in: current).trimmingCharacters(in: .newlines) + "\n" + block
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public func intervalEntries(in markdown: String) -> String {
        guard let start = markdown.range(of: Self.dailyMarker) else { return markdown }
        guard let end = markdown.range(of: Self.dailyEndMarker, range: start.upperBound..<markdown.endIndex) else {
            // Older versions wrote an unbounded daily section at the end of the file.
            return String(markdown[..<start.lowerBound])
        }
        return String(markdown[..<start.lowerBound]) + String(markdown[end.upperBound...])
    }

    public func previousDiary(before date: Date) throws -> String {
        let calendar = Calendar.current
        let dates = [date, calendar.date(byAdding: .day, value: -1, to: date)].compactMap { $0 }
        for day in dates {
            guard let markdown = try readWorklog(for: day) else { continue }
            let entries = intervalEntries(in: markdown).components(separatedBy: "\n## ").dropFirst()
            if let last = entries.last(where: { $0.contains("### Activity") }) {
                return SecretRedactor().redact(String(last.prefix(2500)))
            }
        }
        return ""
    }

    public func readWorklog(for date: Date) throws -> String? {
        let url = worklogURL(for: date)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    public static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

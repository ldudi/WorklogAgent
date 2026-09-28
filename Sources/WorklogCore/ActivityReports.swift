import Foundation

public enum ReportPeriod: String, Sendable { case today, week, month
    public func range(containing date: Date, calendar: Calendar = .current) throws -> DateInterval {
        var calendar = calendar
        calendar.firstWeekday = 2
        let component: Calendar.Component = self == .today ? .day : (self == .week ? .weekOfYear : .month)
        guard let interval = calendar.dateInterval(of: component, for: date) else { throw ActivityValidationError.invalid("Invalid report date") }
        return interval
    }
    public func previous(_ range: DateInterval, calendar: Calendar = .current) throws -> DateInterval {
        try self.range(containing: range.start.addingTimeInterval(-1), calendar: calendar)
    }
}
public struct FocusBlock: Codable, Sendable {
    public var start: Date
    public var end: Date
    public var projectID: String?
    public var duration: Double { end.timeIntervalSince(start) }
}
public struct ActivityStatistics: Encodable, Sendable {
    public var start: Date
    public var end: Date
    public var tracked: Double
    public var active: Double
    public var unclear: Double
    public var byCategory: [String: Double]
    public var byIntent: [String: Double]
    public var byProject: [String: Double]
    public var focusBlocks: [FocusBlock]
    public var contextSwitches: Int
    public var creation: Double { (byIntent["BUILD"] ?? 0) + (byIntent["FIX"] ?? 0) }
    public var consumption: Double { byIntent["CONSUME"] ?? 0 }
    public var researchLearning: Double { (byIntent["RESEARCH"] ?? 0) + (byIntent["LEARN"] ?? 0) }
    public var switchesPerActiveHour: Double { active > 0 ? Double(contextSwitches) / (active / 3600) : 0 }
    public var averageFocus: Double { focusBlocks.isEmpty ? 0 : focusBlocks.map(\.duration).reduce(0, +) / Double(focusBlocks.count) }
    private enum CodingKeys: String, CodingKey {
        case start, end, tracked, active, unclear, byCategory, byIntent, byProject, focusBlocks, contextSwitches
        case creation, consumption, researchLearning, switchesPerActiveHour, averageFocus, medianFocus, longestFocus
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(start, forKey: .start); try box.encode(end, forKey: .end)
        try box.encode(tracked, forKey: .tracked); try box.encode(active, forKey: .active); try box.encode(unclear, forKey: .unclear)
        try box.encode(byCategory, forKey: .byCategory); try box.encode(byIntent, forKey: .byIntent); try box.encode(byProject, forKey: .byProject)
        try box.encode(focusBlocks, forKey: .focusBlocks); try box.encode(contextSwitches, forKey: .contextSwitches)
        try box.encode(creation, forKey: .creation); try box.encode(consumption, forKey: .consumption); try box.encode(researchLearning, forKey: .researchLearning)
        try box.encode(switchesPerActiveHour, forKey: .switchesPerActiveHour); try box.encode(averageFocus, forKey: .averageFocus)
        try box.encode(medianFocus, forKey: .medianFocus); try box.encode(focusBlocks.map(\.duration).max() ?? 0, forKey: .longestFocus)
    }
    public var medianFocus: Double {
        let values = focusBlocks.map(\.duration).sorted()
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }
}
public struct ActivityAnalytics {
    public var focusThreshold: Double
    public var minimumMeaningfulDuration: Double
    public init(focusThreshold: Double = 25 * 60, minimumMeaningfulDuration: Double = 2 * 60) {
        self.focusThreshold = max(1, focusThreshold); self.minimumMeaningfulDuration = max(1, minimumMeaningfulDuration)
    }
    public func statistics(store: ActivityStore, from: Date, to: Date) async throws -> ActivityStatistics {
        let records = try await store.records(from: from, to: to)
        let categories = try await store.totals(from: from, to: to, dimension: "category")
        let intents = try await store.totals(from: from, to: to, dimension: "intent")
        let projects = try await store.totals(from: from, to: to, dimension: "project_id")
        let tracked = categories.values.reduce(0, +)
        let unclear = records.filter { $0.category == .unclear || $0.intent == .unknown }.reduce(0) { $0 + max(0, min($1.end, to).timeIntervalSince(max($1.start, from))) }
        let blocks = coherentBlocks(records: records, from: from, to: to)
        let meaningful = blocks.filter { $0.block.duration >= minimumMeaningfulDuration }
        var switches = 0
        for (previous, next) in zip(meaningful, meaningful.dropFirst()) {
            if previous.state != next.state && next.block.start.timeIntervalSince(previous.block.end) <= 300 { switches += 1 }
        }
        return ActivityStatistics(start: from, end: to, tracked: tracked, active: tracked - unclear, unclear: unclear,
            byCategory: categories, byIntent: intents, byProject: projects,
            focusBlocks: blocks.map(\.block).filter { $0.duration >= focusThreshold }, contextSwitches: switches)
    }
    private func coherentBlocks(records: [ActivityRecord], from: Date, to: Date) -> [(state: String, block: FocusBlock)] {
        var blocks: [(state: String, block: FocusBlock)] = []
        for record in records where record.category != .unclear && record.intent != .unknown {
            let start = max(from, record.start), end = min(to, record.end)
            guard end > start else { continue }
            // An unassigned activity needs the same title as well as category/intent to establish continuity.
            let state = [record.projectID ?? record.title.lowercased(), record.intent.rawValue, record.category.rawValue].joined(separator: ":")
            if let last = blocks.last, last.state == state, start == last.block.end {
                blocks[blocks.count - 1].block.end = end
            } else { blocks.append((state, FocusBlock(start: start, end: end, projectID: record.projectID))) }
        }
        return blocks
    }
}
public struct ActivityReport {
    public var outputDirectory: URL
    public var analytics: ActivityAnalytics
    public init(outputDirectory: URL, focusThreshold: Double = 25 * 60) {
        self.outputDirectory = outputDirectory; analytics = ActivityAnalytics(focusThreshold: focusThreshold)
    }
    public func render(store: ActivityStore, period: ReportPeriod, date: Date) async throws -> String {
        let range = try period.range(containing: date)
        let stats = try await analytics.statistics(store: store, from: range.start, to: range.end)
        let records = try await store.records(from: range.start, to: range.end)
        let names = try await store.projectNames()
        func periodFacts(_ rows: [ActivityRecord]) -> [ActivityFact] {
            rows.flatMap { record in record.facts.filter { fact in
                let timestamp = fact.timestamp ?? record.end
                return timestamp >= range.start && timestamp < range.end
            } }
        }
        let title = period == .today ? WorklogWriter.displayDate(date) : "\(period == .week ? "Weekly Review" : "Monthly Review") — \(WorklogWriter.dayKey(range.start)) to \(WorklogWriter.dayKey(range.end.addingTimeInterval(-1)))"
        var lines = ["# \(title)", "", "<!-- WORKLOG_SQLITE_PROJECTION v1 -->", "", "## \(period == .today ? "Day at a glance" : "Overview")", "",
            "Tracked coverage (estimated activity allocation): **\(Self.duration(stats.tracked))**",
            "Active/classified: \(Self.duration(stats.active)) · Unclear: \(Self.duration(stats.unclear))",
            "", "| Intent | Time |", "| --- | --- |"]
        for intent in ActivityIntent.allCases { if let seconds = stats.byIntent[intent.rawValue], seconds > 0 { lines.append("| \(intent.rawValue) | \(Self.duration(seconds)) |") } }
        lines += ["", "Focus blocks (≥ \(Int(analytics.focusThreshold / 60)) min): \(stats.focusBlocks.count)",
            "Meaningful context switches: \(stats.contextSwitches)",
            "Average / median focus: \(Self.duration(stats.averageFocus)) / \(Self.duration(stats.medianFocus))", "",
            "Screen evidence estimates activity; tracked coverage does not prove continuous attention or keyboard activity.", "", "## Time by category", ""]
        lines += stats.byCategory.sorted { $0.value > $1.value }.map { "- \($0.key): \(Self.duration($0.value))" }
        lines += ["", "## Projects", ""]
        for entry in stats.byProject.sorted(by: { $0.value > $1.value }) {
            lines += ["### \(Self.escape(names[entry.key] ?? "Unassigned")) — \(Self.duration(entry.value))", "", "Work:"]
            let selected = records.filter { ($0.projectID ?? "unassigned") == entry.key }
            lines += Array(Set(selected.map { "- \(Self.escape($0.title))" })).sorted()
            let facts = periodFacts(selected)
            for kind in [FactKind.outcome, .problem, .decision] {
                let values = facts.filter { $0.kind == kind }
                if !values.isEmpty {
                    lines += ["", "\(kind.rawValue.capitalized)s:"]
                    lines += Array(Set(values.map { "- \(Self.escape($0.text)) (inferred, confidence \(Int($0.confidence * 100))%)" })).sorted()
                }
            }
            lines.append("")
        }
        lines += ["## Creation vs consumption", "", "Creation (BUILD + FIX): \(Self.duration(stats.creation))",
                  "Research + learning: \(Self.duration(stats.researchLearning))", "Consumption: \(Self.duration(stats.consumption))",
                  "Planning is reported separately. These are allocations, not a score.", "", "## Research & learning", ""]
        lines += records.filter { $0.intent == .learn || $0.intent == .research }.map { "- \(Self.escape($0.title))" }
        lines += ["", "## Consumption / background context", ""]
        lines += records.filter { $0.intent == .consume }.map { "- \(WorklogWriter.time($0.start))–\(WorklogWriter.time($0.end)): \(Self.escape($0.title))" }
        lines += records.filter { !$0.backgroundContext.isEmpty }.map { "- Background: \(Self.escape($0.backgroundContext)) (no additional time allocated)" }
        lines += ["", "## Significant outcomes", ""]
        let outcomes = periodFacts(records).filter { $0.kind == .outcome }
        lines += outcomes.isEmpty ? ["No evidence-backed outcomes recorded."] : outcomes.map { "- \(Self.escape($0.text)) (inferred; \($0.evidenceIDs.count) evidence references)" }
        lines += ["", "## Open loops", ""]
        let open = periodFacts(records).filter { $0.kind == .problem && $0.status != .resolved }
        lines += open.isEmpty ? ["No unresolved problems recorded; absence is not proof of completion."] : open.map { "- \(Self.escape($0.text)) (\($0.status?.rawValue ?? "UNKNOWN"))" }
        if period != .today {
            let previous = try period.previous(range)
            let old = try await analytics.statistics(store: store, from: previous.start, to: previous.end)
            lines += ["", "## Change from previous \(period.rawValue)", "", "| Metric | Previous | Current | Change |", "| --- | --- | --- | --- |"]
            for (label, before, after) in [("Tracked", old.tracked, stats.tracked), ("Creation", old.creation, stats.creation), ("Research + learning", old.researchLearning, stats.researchLearning), ("Consumption", old.consumption, stats.consumption), ("Average focus", old.averageFocus, stats.averageFocus)] {
                let difference = after - before
                lines.append("| \(label) | \(Self.duration(before)) | \(Self.duration(after)) | \(difference < 0 ? "−" : "+")\(Self.duration(abs(difference))) |")
            }
            lines += ["", "Context switches: \(old.contextSwitches) → \(stats.contextSwitches)", "",
                "Comparisons reflect recorded coverage; incomplete periods and missing previous history limit interpretation.", "", "## Considerations", ""]
            lines += old.tracked == 0 ? ["No previous-period history is recorded, so improvement or decline cannot be established."] : ["Review coverage differences before interpreting changes in time allocation."]
            if !open.isEmpty { lines.append("\(open.count) unresolved problem observations may warrant review; recurrence and lifecycle linking are not yet inferred.") }
        }
        lines += ["", "## Timeline", ""]
        for record in records {
            let span = "\(WorklogWriter.time(max(record.start, range.start)))–\(WorklogWriter.time(min(record.end, range.end)))"
            let day = period == .today ? "" : WorklogWriter.dayKey(record.start) + " "
            lines.append("- \(day)\(span) **\(Self.escape(record.title))** · \(record.category.rawValue) / \(record.intent.rawValue) · \(record.provenance.rawValue), \(Int(record.confidence * 100))% · `\(record.id.prefix(12))`")
            if !record.summary.isEmpty { lines.append("  \(Self.escape(record.summary))") }
        }
        if records.isEmpty { lines.append("No canonical activity records for this period.") }
        return lines.joined(separator: "\n") + "\n"
    }
    @discardableResult
    public func write(store: ActivityStore, period: ReportPeriod, date: Date) async throws -> URL {
        let markdown = try await render(store: store, period: period, date: date)
        let range = try period.range(containing: date)
        let name = period == .today ? WorklogWriter.dayKey(date) : "\(period.rawValue)-\(WorklogWriter.dayKey(range.start))"
        let url = outputDirectory.appendingPathComponent(name + ".md")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let current = try String(contentsOf: url, encoding: .utf8)
            if !current.contains("<!-- WORKLOG_SQLITE_PROJECTION v1 -->") {
                let backupDir = outputDirectory.appendingPathComponent("legacy-backups")
                try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: backupDir.appendingPathComponent(name + "-" + UUID().uuidString + ".md"))
            }
        }
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|") }
}

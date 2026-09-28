import Foundation
import WorklogCore

#if canImport(Glibc)
import Glibc
#endif

@main
struct WorklogAgentCLI {
    static func main() async {
        do {
            let parsed = try Arguments(CommandLine.arguments)
            var config = WorklogConfiguration()
            if let model = parsed.value("model") { config.model = model }
            if let interval = parsed.intValue("interval") { config.intervalMinutes = max(1, interval) }
            if let lookback = parsed.intValue("minutes") { config.summaryLookbackMinutes = max(1, lookback) }
            if let output = parsed.value("output") { config.outputDirectory = expandPath(output) }
            if let justNow = parsed.value("justnow") { config.justNowDirectory = expandPath(justNow) }
            if let ollama = parsed.value("ollama"), let url = URL(string: ollama) { config.ollamaBaseURL = url }
            if parsed.flag("no-daily-summary") { config.autoDailySummary = false }
            if parsed.flag("no-images") { config.useScreenshots = false }
            if let path = parsed.value("diagnostics") { config.diagnosticsDirectory = expandPath(path) }
            if let path = parsed.value("database") { config.databaseURL = expandPath(path) }
            if let threshold = parsed.intValue("focus-minutes") { config.focusThresholdMinutes = max(1, threshold) }
            let projectsURL = parsed.value("projects-config").map(expandPath) ?? ActivityStore.defaultURL.deletingLastPathComponent().appendingPathComponent("projects.json")
            if FileManager.default.fileExists(atPath: projectsURL.path) {
                config.projectConfiguration = try JSONDecoder().decode(ProjectConfiguration.self, from: Data(contentsOf: projectsURL))
            }
            guard ["127.0.0.1", "localhost", "::1", "[::1]"].contains(config.ollamaBaseURL.host ?? "") else { throw CLIError("Ollama must use a local loopback URL") }

            let engine = WorklogEngine(configuration: config)
            let command = parsed.command ?? "doctor"

            switch command {
            case "doctor":
                let lines = await engine.doctor()
                print(lines.joined(separator: "\n"))
            case "models":
                let models = try await engine.availableModels()
                if models.isEmpty { print("No Ollama models installed.") }
                for model in models { print(model.name) }
            case "inspect":
                print(try await engine.inspect(minutes: config.summaryLookbackMinutes))
            case "summarize":
                if let from = parsed.value("from"), let to = parsed.value("to") {
                    printResult(try await engine.summarizeInterval(start: parseDate(from), end: parseDate(to), inspectionOnly: parsed.flag("inspect-only"), reprocess: parsed.flag("reprocess")))
                } else if parsed.value("from") != nil || parsed.value("to") != nil {
                    throw CLIError("Explicit summarization requires both --from and --to")
                } else {
                    if parsed.flag("reprocess") { throw CLIError("--reprocess requires an exact --from and --to interval") }
                    printResult(try await engine.summarizeNow(minutesOverride: parsed.intValue("minutes")))
                }
            case "daily":
                if let url = try await engine.summarizeDay() {
                    print("Daily summary refreshed at \(url.path)")
                } else {
                    print("No worklog exists for today yet.")
                }
            case "report", "stats":
                guard let period = ReportPeriod(rawValue: parsed.positionals.first ?? "today") else { throw CLIError("Period must be today, week, or month") }
                let date = try parsed.value("date").map(parseDate) ?? Date()
                let store = try await engine.activityStore()
                if command == "report" {
                    let report = ActivityReport(outputDirectory: config.outputDirectory, focusThreshold: Double(config.focusThresholdMinutes * 60))
                    let url = try await report.write(store: store, period: period, date: date)
                    print(try await report.render(store: store, period: period, date: date))
                    print("Saved \(url.path)")
                } else {
                    let range = try period.range(containing: date)
                    let stats = try await ActivityAnalytics(focusThreshold: Double(config.focusThresholdMinutes * 60)).statistics(store: store, from: range.start, to: range.end)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    print(String(decoding: try encoder.encode(stats), as: UTF8.self))
                }
            case "search":
                let from = try parsed.value("from").map(parseDate) ?? Date(timeIntervalSince1970: 0)
                let to = try parsed.value("to").map(parseDate) ?? Date()
                let category = try parsed.value("category").map { raw -> ActivityCategory in
                    guard let value = ActivityCategory(rawValue: raw) else { throw CLIError("Unknown category: \(raw)") }; return value
                }
                let intent = try parsed.value("intent").map { raw -> ActivityIntent in
                    guard let value = ActivityIntent(rawValue: raw) else { throw CLIError("Unknown intent: \(raw)") }; return value
                }
                let kind = try parsed.value("fact").map { raw -> FactKind in
                    guard let value = FactKind(rawValue: raw) else { throw CLIError("Fact must be outcome, problem, or decision") }; return value
                }
                let store = try await engine.activityStore()
                let records = try await store.search(ActivitySearch(from: from, to: to, text: parsed.positionals.isEmpty ? nil : parsed.positionals.joined(separator: " "),
                    project: parsed.value("project"), category: category, intent: intent, entity: parsed.value("entity"), factKind: kind, limit: parsed.intValue("limit") ?? 100))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(records), as: UTF8.self))
            case "import-markdown":
                guard let directory = parsed.positionals.first else { throw CLIError("import-markdown requires a directory") }
                let store = try await engine.activityStore()
                let result = try await LegacyMarkdownImporter().importDirectory(expandPath(directory), into: store)
                print("Imported \(result.importedIntervals) non-overlapping legacy intervals (\(ActivityReport.duration(result.importedSeconds))). Skipped \(result.skippedEntries) unsupported/covered entries. Original Markdown unchanged.")
            case "projects":
                let store = try await engine.activityStore()
                let stored = try await store.registeredProjects()
                let projects = Dictionary((stored + config.projectConfiguration.projects).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.name < $1.name }
                for project in projects { print("\(project.name): aliases=\(project.aliases.joined(separator: ", ")) repository=\(project.repository ?? "unconfigured")") }
                if projects.isEmpty { print("No projects configured. Use projects.json or --projects-config.") }
            case "correct":
                guard let id = parsed.positionals.first else { throw CLIError("correct requires the full activity ID from search") }
                let category = try parsed.value("category").map { raw -> ActivityCategory in
                    guard let value = ActivityCategory(rawValue: raw) else { throw CLIError("Unknown category") }; return value
                }
                let intent = try parsed.value("intent").map { raw -> ActivityIntent in
                    guard let value = ActivityIntent(rawValue: raw) else { throw CLIError("Unknown intent") }; return value
                }
                guard category != nil || intent != nil || parsed.value("title") != nil else { throw CLIError("Provide --title, --category, or --intent") }
                let store = try await engine.activityStore()
                try await store.correct(id: id, correction: ActivityCorrection(title: parsed.value("title"), category: category, intent: intent))
                print("Correction preserved as USER_CONFIRMED. Regenerate affected reports with report --date.")
            case "daemon":
                print("WorklogAgent daemon running. Interval: \(config.intervalMinutes) min; model: \(config.model)")
                print("Output: \(config.outputDirectory.path)")
                var nextSummary = Date()
                while true {
                    let now = Date()
                    do {
                        let dailyDue = await engine.shouldRunDailySummary(now: now)
                        if dailyDue {
                            let result = try await engine.summarizeNow(now: now)
                            printResult(result)
                            if let url = try await engine.summarizeDay(now, markAutomatic: true) {
                                print("Daily report regenerated at \(url.path)")
                            }
                            nextSummary = now.addingTimeInterval(TimeInterval(max(1, config.intervalMinutes) * 60))
                        } else if now >= nextSummary {
                            let result = try await engine.summarizeNow(now: now)
                            printResult(result)
                            nextSummary = now.addingTimeInterval(TimeInterval(max(1, config.intervalMinutes) * 60))
                        }
                    } catch {
                        fputs("[WorklogAgent] \(error.localizedDescription)\n", stderr)
                    }
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
            case "help", "--help", "-h":
                printHelp()
            default:
                throw CLIError("Unknown command: \(command)")
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            printHelp()
            exit(1)
        }
    }

    static func printResult(_ result: SummaryResult) {
        if let url = result.outputURL {
            print("Summarized \(result.rawObservationCount) OCR observations (\(result.retainedObservationCount) cleaned states), with \(result.screenshotCount) representative screenshots.")
            print("Updated \(url.path)")
        } else if let markdown = result.markdown {
            print("Inspection only; canonical history and checkpoint unchanged.\n" + markdown)
        } else { print("No new interval or meaningful evidence.") }
    }

    static func expandPath(_ path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    static func parseDate(_ value: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
        if let date = day.date(from: value), day.string(from: date) == value { return date }
        throw CLIError("Invalid date: \(value). Use YYYY-MM-DD or ISO 8601 with timezone.")
    }

    static func printHelp() {
        print("""
        WorklogAgent — JustNow → local Ollama → SQLite → reports

        Usage:
          swift run WorklogAgent doctor
          swift run WorklogAgent inspect --minutes 30
          swift run WorklogAgent summarize
          swift run WorklogAgent summarize --minutes 90  (inspection only)
          swift run WorklogAgent summarize --from <ISO date/time> --to <ISO date/time>
          swift run WorklogAgent report today|week|month [--date YYYY-MM-DD]
          swift run WorklogAgent stats today|week|month [--date YYYY-MM-DD]
          swift run WorklogAgent search "Ollama" [--from YYYY-MM-DD] [--to YYYY-MM-DD]
          swift run WorklogAgent search --project <name> --category coding --intent BUILD
          swift run WorklogAgent search --entity <name> --fact outcome|problem|decision
          swift run WorklogAgent import-markdown <directory>
          swift run WorklogAgent projects
          swift run WorklogAgent correct <full-id> --title <text> --category <category> --intent <intent>
          swift run WorklogAgent daily   (alias for today's SQLite projection)
          swift run WorklogAgent models
          swift run WorklogAgent daemon [--interval 90]

        Options:
          --model <name>           Default gemma4:e4b
          --interval <minutes>     Automatic chunk size, default 90
          --minutes <minutes>      Inspection lookback; never persists duplicate history
          --database <path>        Owned SQLite path
          --output <path>          Markdown projection directory
          --projects-config <path> Project/alias JSON configuration
          --focus-minutes <int>    Focus threshold, default 25
          --limit <int>            Search limit, default 100 (maximum 10,000)
          --justnow <path>         Read-only JustNow directory
          --ollama <url>           Local loopback Ollama, default http://127.0.0.1:11434
          --inspect-only          Explicit --from/--to inspection without persistence
          --reprocess             Replace the exact unconfirmed interval; refuses user corrections
          --diagnostics <path>    Opt-in local redacted failed-response diagnostics
          --no-images             Text-only reconstruction
          --no-daily-summary       Disable scheduled daily projection

        Date ranges are half-open [from,to). Date-only --to is midnight at the start of that date.
        """)
    }
}

private struct Arguments {
    let command: String?
    let positionals: [String]
    private let options: [String: String]
    private let flags: Set<String>

    init(_ argv: [String]) throws {
        if argv.dropFirst().contains("--help") || argv.dropFirst().contains("-h") {
            self.command = "help"; self.positionals = []; self.options = [:]; self.flags = []; return
        }
        var tokens = Array(argv.dropFirst())
        var command: String?
        if let first = tokens.first, !first.hasPrefix("-") {
            command = first
            tokens.removeFirst()
        }

        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token.hasPrefix("--") else { positionals.append(token); index += 1; continue }
            let key = String(token.dropFirst(2))
            if ["no-daily-summary", "no-images", "inspect-only", "reprocess"].contains(key) {
                flags.insert(key)
                index += 1
                continue
            }
            guard ["model", "interval", "minutes", "output", "justnow", "ollama", "database", "projects-config", "focus-minutes", "from", "to", "date", "project", "category", "intent", "entity", "fact", "limit", "title", "diagnostics"].contains(key) else { throw CLIError("Unknown option --\(key)") }
            guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else { throw CLIError("Missing value for --\(key)") }
            options[key] = tokens[index + 1]
            index += 2
        }
        self.command = command
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    func value(_ key: String) -> String? { options[key] }
    func intValue(_ key: String) -> Int? { options[key].flatMap(Int.init) }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

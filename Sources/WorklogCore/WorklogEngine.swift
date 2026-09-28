import Foundation

public actor WorklogEngine {
    public var configuration: WorklogConfiguration
    private let stateStore: StateStore
    private let injectedClient: OllamaClient?
    private var isProcessing = false
    private var pendingConfiguration: WorklogConfiguration?

    public init(configuration: WorklogConfiguration, stateStore: StateStore = StateStore(), ollamaClient: OllamaClient? = nil) {
        self.configuration = configuration
        self.stateStore = stateStore
        self.injectedClient = ollamaClient
    }

    public func updateConfiguration(_ configuration: WorklogConfiguration) {
        if isProcessing { pendingConfiguration = configuration } else { self.configuration = configuration }
    }

    public func doctor() async -> [String] {
        var lines: [String] = []
        let reader = JustNowReader(directory: configuration.justNowDirectory)
        do {
            try reader.validate()
            lines.append("✓ JustNow databases found at \(configuration.justNowDirectory.path)")
        } catch {
            lines.append("✗ \(error.localizedDescription)")
        }

        do {
            let models = try await client().listModels()
            lines.append("✓ Ollama reachable at \(configuration.ollamaBaseURL.absoluteString)")
            if models.contains(where: { $0.name == configuration.model || $0.model == configuration.model }) {
                lines.append("✓ Model installed: \(configuration.model)")
                if configuration.useScreenshots {
                    let vision = try await client().supportsVision(model: configuration.model)
                    lines.append(vision ? "✓ Vision supported; up to 6 representative images per summary" : "✓ Text-only fallback; selected model has no vision capability")
                }
            } else {
                lines.append("✗ Model not found: \(configuration.model)")
            }
        } catch {
            lines.append("✗ \(error.localizedDescription)")
        }

        do {
            try WorklogWriter(outputDirectory: configuration.outputDirectory).validateWriteAccess(for: Date())
            lines.append("✓ Worklog output: \(configuration.outputDirectory.path)")
        } catch {
            lines.append("✗ \(error.localizedDescription)")
        }
        do {
            let store = try activityStore()
            lines.append("✓ Owned SQLite schema v\(try await store.version()): \(configuration.databaseURL.path)")
        } catch { lines.append("✗ \(error.localizedDescription)") }
        return lines
    }

    private func client() -> OllamaClient { injectedClient ?? OllamaClient(baseURL: configuration.ollamaBaseURL) }

    public func availableModels() async throws -> [OllamaModel] {
        try await client().listModels()
    }

    public func activityStore() throws -> ActivityStore {
        let target = configuration.databaseURL.resolvingSymlinksInPath().standardizedFileURL
        let reader = JustNowReader(directory: configuration.justNowDirectory)
        guard target != reader.framesDatabaseURL.resolvingSymlinksInPath().standardizedFileURL,
              target != reader.textDatabaseURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw ActivityValidationError.invalid("JustNow databases are read-only external evidence")
        }
        return try ActivityStore(url: configuration.databaseURL)
    }

    public func summarizeNow(minutesOverride: Int? = nil, now: Date = Date()) async throws -> SummaryResult {
        if let minutesOverride {
            let end = now.addingTimeInterval(-TimeInterval(max(0, configuration.graceSeconds)))
            return try await summarizeInterval(start: end.addingTimeInterval(-Double(max(1, minutesOverride) * 60)), end: end, inspectionOnly: true)
        }
        guard !isProcessing else { throw ActivityValidationError.invalid("A canonical summary is already running") }
        isProcessing = true
        defer {
            isProcessing = false
            if let pendingConfiguration { configuration = pendingConfiguration; self.pendingConfiguration = nil }
        }
        let store = try activityStore()
        let end = now.addingTimeInterval(-TimeInterval(max(0, configuration.graceSeconds)))
        var start = try await store.checkpoint() ?? end.addingTimeInterval(-Double(max(1, configuration.intervalMinutes) * 60))
        guard start < end else { return SummaryResult(start: start, end: end, rawObservationCount: 0, retainedObservationCount: 0, markdown: nil, outputURL: nil) }
        var raw = 0, retained = 0, images = 0
        var last: SummaryResult?
        let originalStart = start
        let ranges = try await store.unprocessedRanges(from: start, to: end)
        // Catch-up windows stay bounded and split at local midnight; previously processed explicit ranges are skipped.
        for range in ranges {
            start = range.start
            while start < range.end {
                try Task.checkCancellation()
                guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start)) else { throw ActivityValidationError.invalid("Invalid calendar") }
                let stop = min(range.end, min(start.addingTimeInterval(Double(max(1, configuration.intervalMinutes) * 60)), nextDay))
                let result = try await processInterval(start: start, end: stop, inspectionOnly: false, store: store)
                raw += result.rawObservationCount; retained += result.retainedObservationCount; images += result.screenshotCount
                last = result; start = stop
            }
        }
        return SummaryResult(start: originalStart, end: end, rawObservationCount: raw, retainedObservationCount: retained,
                             screenshotCount: images, markdown: last?.markdown, outputURL: last?.outputURL)
    }

    public func inspect(minutes: Int = 90, now: Date = Date()) throws -> String {
        let end = now.addingTimeInterval(-TimeInterval(max(0, configuration.graceSeconds)))
        let start = end.addingTimeInterval(-TimeInterval(max(1, minutes) * 60))
        let reader = JustNowReader(directory: configuration.justNowDirectory)
        let raw = try reader.observations(from: start, to: end)
        let cleaned = ActivityPreprocessor().clean(raw)
        let states = OCRDeduplicator().deduplicate(cleaned)
        let context = ContextBuilder(maxCharacters: configuration.maxContextCharacters).build(from: states)
        let screenshots = configuration.useScreenshots ? try reader.representativeScreenshots(from: start, to: end) : []
        return """
        Interval: \(WorklogWriter.time(start))–\(WorklogWriter.time(end))
        Raw observations: \(raw.count)
        After quality filtering: \(cleaned.count)
        Screen states: \(states.count)
        Displays: \(Set(states.compactMap(\.displayName) + screenshots.map(\.displayName)).count)
        Evidence characters: \(context.count) / \(configuration.maxContextCharacters)
        Representative screenshots available: \(screenshots.count)
        \(screenshots.map { "\(WorklogWriter.time($0.startedAt)) | \($0.displayName) | \($0.url.path)" }.joined(separator: "\n"))

        Cleaned representative evidence:
        \(context)
        """
    }

    public func summarizeInterval(start: Date, end: Date, inspectionOnly: Bool = false, reprocess: Bool = false) async throws -> SummaryResult {
        guard !isProcessing else { throw ActivityValidationError.invalid("A canonical summary is already running") }
        isProcessing = true
        defer {
            isProcessing = false
            if let pendingConfiguration { configuration = pendingConfiguration; self.pendingConfiguration = nil }
        }
        return try await processInterval(start: start, end: end, inspectionOnly: inspectionOnly, store: activityStore(), reprocess: reprocess)
    }

    private func processInterval(start: Date, end: Date, inspectionOnly: Bool, store: ActivityStore, reprocess: Bool = false) async throws -> SummaryResult {
        if !inspectionOnly, end > Date().addingTimeInterval(1) { throw ActivityValidationError.invalid("Canonical intervals cannot extend into the future") }
        if !inspectionOnly { try WorklogWriter(outputDirectory: configuration.outputDirectory).validateWriteAccess(for: start) }
        guard end > start, end.timeIntervalSince(start) <= 24 * 3600 else { throw ActivityValidationError.invalid("Use intervals up to one day") }
        let report = ActivityReport(outputDirectory: configuration.outputDirectory, focusThreshold: Double(configuration.focusThresholdMinutes * 60))
        if !inspectionOnly {
            if !reprocess, try await store.containsWindow(start: start, end: end) {
                let url = try await report.write(store: store, period: .today, date: start)
                return SummaryResult(start: start, end: end, rawObservationCount: 0, retainedObservationCount: 0,
                                     markdown: try await report.render(store: store, period: .today, date: start), outputURL: url)
            }
            try await store.checkAvailable(start: start, end: end)
        }
        let reader = JustNowReader(directory: configuration.justNowDirectory)
        let raw = try reader.observations(from: start, to: end)
        let deduped = OCRDeduplicator().deduplicate(ActivityPreprocessor().clean(raw))
        let window = intervalID(start, end)
        var evidence = evenlySpaced(deduped, limit: 24).enumerated().map { index, row in
            ActivityEvidence(id: stableID("\(window):ocr:\(index)"), timestamp: row.startedAt, display: row.displayName,
                excerpt: SecretRedactor().redact(String(row.text.prefix(900))), type: "ocr", confidence: 0.6, sourceReference: "justnow:frame/\(row.frameID)/span/\(row.id)")
        }
        let client = client()
        var projects = configuration.projectConfiguration
        let projectsURL = ActivityStore.defaultURL.deletingLastPathComponent().appendingPathComponent("projects.json")
        if projects.projects.isEmpty, FileManager.default.fileExists(atPath: projectsURL.path) {
            projects = try JSONDecoder().decode(ProjectConfiguration.self, from: Data(contentsOf: projectsURL))
        } else if projects.projects.isEmpty {
            projects = ProjectConfiguration(projects: try await store.registeredProjects())
        }
        var screenshots: [ScreenshotEvidence] = []
        if configuration.useScreenshots {
            let available = try reader.representativeScreenshots(from: start, to: end)
            if !available.isEmpty, try await client.supportsVision(model: configuration.model) { screenshots = available }
        }
        var imageCount = 0
        for (index, screenshot) in screenshots.enumerated() {
            try Task.checkCancellation()
            guard let encoded = screenshot.encodedImage() else { continue }
            do {
                let facts = try await client.describeScreenshot(model: configuration.model, image: encoded)
                evidence.append(ActivityEvidence(id: stableID("\(window):image:\(index)"), timestamp: screenshot.startedAt,
                    display: screenshot.displayName, excerpt: facts, screenshotReference: screenshot.url.path,
                    type: "visionInference", confidence: 0.65, sourceReference: "justnow:screenshot/\(screenshot.id)", provenance: .inferred))
                imageCount += 1
            } catch WorklogError.invalidSummaryResponse {
                // A failed vision decode does not discard available OCR evidence.
                continue
            }
        }
        let records: [ActivityRecord]
        if evidence.isEmpty { records = [] }
        else {
            records = try await client.reconstructActivities(model: configuration.model, evidence: evidence, start: start, end: end,
                projects: projects, maxContextCharacters: configuration.maxContextCharacters, diagnosticsDirectory: configuration.diagnosticsDirectory)
        }
        if inspectionOnly {
            let markdown = records.map { "\(WorklogWriter.time($0.start))–\(WorklogWriter.time($0.end)): \($0.title) · \($0.category.rawValue) / \($0.intent.rawValue)" }.joined(separator: "\n")
            return SummaryResult(start: start, end: end, rawObservationCount: raw.count, retainedObservationCount: deduped.count,
                screenshotCount: imageCount, markdown: markdown, outputURL: nil)
        }
        try Task.checkCancellation()
        try await store.persist(start: start, end: end, records: records, evidence: evidence, projects: projects, reprocess: reprocess)
        let url = try await report.write(store: store, period: .today, date: start)
        // Explicit intervals can cross midnight; refresh each affected day too.
        var day = Calendar.current.startOfDay(for: start)
        while let next = Calendar.current.date(byAdding: .day, value: 1, to: day), next < end {
            _ = try await report.write(store: store, period: .today, date: next); day = next
        }
        return SummaryResult(start: start, end: end, rawObservationCount: raw.count, retainedObservationCount: deduped.count,
            screenshotCount: imageCount, markdown: try await report.render(store: store, period: .today, date: start), outputURL: url)
    }

    public func summarizeDay(_ date: Date = Date(), markAutomatic: Bool = false) async throws -> URL? {
        let store = try activityStore()
        let url = try await ActivityReport(outputDirectory: configuration.outputDirectory, focusThreshold: Double(configuration.focusThresholdMinutes * 60))
            .write(store: store, period: .today, date: date)
        if markAutomatic {
            var state = await stateStore.load()
            state.lastDailySummaryDay = WorklogWriter.dayKey(date)
            try await stateStore.save(state)
        }
        return url
    }

    public func shouldRunDailySummary(now: Date = Date()) async -> Bool {
        guard configuration.autoDailySummary else { return false }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        guard hour == 23 && minute >= 50 else { return false }
        let state = await stateStore.load()
        return state.lastDailySummaryDay != WorklogWriter.dayKey(now)
    }

    public func nextScheduledSummary(after date: Date = Date()) -> Date {
        let interval = TimeInterval(max(1, configuration.intervalMinutes) * 60)
        return date.addingTimeInterval(interval)
    }
}

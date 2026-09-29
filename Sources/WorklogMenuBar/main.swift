#if os(macOS)
import AppKit
import SwiftUI
import WorklogCore

@main
@MainActor
struct WorklogMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: MenuBarModel

    init() {
        let model = MenuBarModel()
        _model = StateObject(wrappedValue: model)
        // Start the scheduler at launch, even when the menu has never been opened.
        Task { await model.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .frame(width: 8, height: 8)
                        .foregroundStyle(model.isPaused ? Color.secondary : (model.lastError == nil ? Color.green : Color.red))
                    Text(model.status)
                        .font(.headline)
                }

                if let lastRun = model.lastRun {
                    Text("Last summary: \(lastRun.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let nextRun = model.nextRun, !model.isPaused {
                    Text("Next: \(nextRun.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !model.todayStats.isEmpty { Text(model.todayStats).font(.caption).foregroundStyle(.secondary) }
                Divider()

                Picker("Model", selection: Binding(
                    get: { model.selectedModel },
                    set: { model.setModel($0) }
                )) {
                    if model.models.isEmpty {
                        Text(model.selectedModel).tag(model.selectedModel)
                    } else {
                        ForEach(model.models, id: \.self) { Text($0).tag($0) }
                    }
                }
                .frame(width: 280)

                HStack {
                    Button("Summarize Now") { model.summarizeNow() }
                        .disabled(model.isWorking)
                    Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                }

                Text("Processes new evidence since the saved checkpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Weekly Review") { model.weeklyReview() }.disabled(model.isWorking)
                Button("Summarize Today") { model.summarizeToday() }
                    .disabled(model.isWorking)

                HStack {
                    Button("Open Today's Worklog") { model.openToday() }
                    Button("Open Folder") { model.openOutputFolder() }
                }

                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 300, alignment: .leading)
                    Button("Choose Output Folder…") { model.chooseOutputFolder() }
                        .disabled(model.isWorking)
                }

                Divider()
                SettingsLink { Text("Settings…") }
                Button("Quit Worklog") { NSApplication.shared.terminate(nil) }
            }
            .padding(14)
            .frame(width: 330)
            .task { await model.start() }
        } label: {
            Label("Worklog", systemImage: model.isPaused ? "pause.circle" : "doc.text.magnifyingglass")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 520)
                .padding(20)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var models: [String] = []
    @Published var selectedModel: String
    @Published var intervalMinutes: Int
    @Published var summaryLookbackMinutes: Int
    @Published var dynamicScreenshots: Bool
    @Published var minimumScreenshots: Int
    @Published var maximumScreenshots: Int
    @Published var useScreenshots: Bool
    @Published var outputPath: String
    @Published var autoDailySummary: Bool
    @Published var isPaused = false
    @Published var isWorking = false
    @Published var status = "Starting…"
    @Published var todayStats = ""
    @Published var lastError: String?
    @Published var lastRun: Date?
    @Published var nextRun: Date?

    private var engine: WorklogEngine
    private var loopTask: Task<Void, Never>?
    private var hasStarted = false
    private var accessedOutputURL: URL?

    init() {
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: "model") ?? "gemma4:e4b"
        // Migrate the earlier 30-minute configuration once; later settings remain user-controlled.
        if !defaults.bool(forKey: "ninetyMinuteDefaultsApplied") {
            defaults.set(90, forKey: "intervalMinutes")
            defaults.set(90, forKey: "summaryLookbackMinutes")
            defaults.set(true, forKey: "ninetyMinuteDefaultsApplied")
        }
        let interval = defaults.object(forKey: "intervalMinutes") as? Int ?? 90
        let lookback = defaults.object(forKey: "summaryLookbackMinutes") as? Int ?? 90
        let output = defaults.string(forKey: "outputPath") ?? WorklogConfiguration.defaultOutputDirectory.path
        let daily = defaults.object(forKey: "autoDailySummary") as? Bool ?? true
        let screenshots = defaults.object(forKey: "useScreenshots") as? Bool ?? true

        selectedModel = model
        intervalMinutes = max(1, interval)
        summaryLookbackMinutes = max(1, lookback)
        let selection = ScreenshotSelectionSettings(defaults: defaults)
        dynamicScreenshots = selection.dynamic
        minimumScreenshots = selection.minimum
        maximumScreenshots = selection.maximum
        useScreenshots = screenshots
        outputPath = output
        autoDailySummary = daily

        var config = WorklogConfiguration()
        config.model = model
        config.intervalMinutes = max(1, interval)
        config.summaryLookbackMinutes = max(1, lookback)
        config.useScreenshots = screenshots
        config.screenshotSelection = selection
        config.outputDirectory = URL(fileURLWithPath: output)
        config.autoDailySummary = daily
        engine = WorklogEngine(configuration: config)
        if let bookmark = defaults.data(forKey: "outputFolderBookmark") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { accessedOutputURL = url }
                outputPath = url.path
                config.outputDirectory = url
                engine = WorklogEngine(configuration: config)
                if stale {
                    defaults.set(try url.bookmarkData(options: [.withSecurityScope]), forKey: "outputFolderBookmark")
                }
            } catch {
                lastError = "Output folder access could not be restored. Choose the output folder again."
            }
        }
    }

    deinit {
        loopTask?.cancel()
        accessedOutputURL?.stopAccessingSecurityScopedResource()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refreshModels()
        let doctor = await engine.doctor()
        if doctor.contains(where: { $0.hasPrefix("✗") }) {
            status = "Needs attention"
            lastError = doctor.filter { $0.hasPrefix("✗") }.joined(separator: "\n")
        } else {
            status = "Monitoring"
            lastError = nil
        }
        await refreshStatistics()
        scheduleNext(from: Date())
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { break }
                await self.tick()
            }
        }
    }

    func refreshModels() async {
        do {
            let fetched = try await engine.availableModels().map(\.name)
            models = fetched
            if !fetched.contains(selectedModel), let first = fetched.first {
                setModel(first)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setModel(_ model: String) {
        selectedModel = model
        persistAndApply()
    }

    func applySettings() {
        intervalMinutes = max(1, intervalMinutes)
        summaryLookbackMinutes = max(1, summaryLookbackMinutes)
        outputPath = expandTilde(outputPath)
        var stale = false
        if let bookmark = UserDefaults.standard.data(forKey: "outputFolderBookmark"),
           let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale),
           url.path != outputPath {
            accessedOutputURL?.stopAccessingSecurityScopedResource()
            accessedOutputURL = nil
            UserDefaults.standard.removeObject(forKey: "outputFolderBookmark")
        }
        persistAndApply()
        scheduleNext(from: Date())
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Worklog Output Folder"
        panel.message = "Select your Worklogs folder to allow Worklog to save summaries there."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: expandTilde(outputPath))
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                let bookmark: Data
                do {
                    bookmark = try url.bookmarkData(options: [.withSecurityScope])
                } catch {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
                self.accessedOutputURL?.stopAccessingSecurityScopedResource()
                self.accessedOutputURL = accessing ? url : nil
                UserDefaults.standard.set(bookmark, forKey: "outputFolderBookmark")
                self.outputPath = url.path
                let configurationTask = self.persistAndApply()
                Task {
                    await configurationTask.value
                    let checks = await self.engine.doctor()
                    self.lastError = checks.filter { $0.hasPrefix("✗") }.joined(separator: "\n")
                    if self.lastError?.isEmpty == true { self.lastError = nil }
                    self.status = self.lastError == nil ? (self.isPaused ? "Paused" : "Ready to summarize") : "Needs attention"
                }
            } catch {
                self.lastError = "Could not retain output folder access: \(error.localizedDescription)"
            }
        }
    }

    func togglePause() {
        isPaused.toggle()
        status = isPaused ? "Paused" : "Monitoring"
        if !isPaused { scheduleNext(from: Date()) }
    }

    func summarizeNow() {
        guard !isWorking else { return }
        isWorking = true
        Task { await performSummary() }
    }

    func summarizeToday() {
        guard !isWorking else { return }
        isWorking = true
        Task { await performDailySummary() }
    }

    func weeklyReview() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let store = try await engine.activityStore()
                let url = try await ActivityReport(outputDirectory: URL(fileURLWithPath: expandTilde(outputPath)))
                    .write(store: store, period: .week, date: Date())
                NSWorkspace.shared.open(url)
                status = "Weekly review updated"
            } catch { lastError = error.localizedDescription; status = "Weekly review failed" }
        }
    }

    private func refreshStatistics() async {
        do {
            let store = try await engine.activityStore()
            let range = try ReportPeriod.today.range(containing: Date())
            let stats = try await ActivityAnalytics().statistics(store: store, from: range.start, to: range.end)
            todayStats = "Today: \(ActivityReport.duration(stats.tracked)) tracked · Build: \(ActivityReport.duration(stats.byIntent["BUILD"] ?? 0)) · Research: \(ActivityReport.duration(stats.byIntent["RESEARCH"] ?? 0))"
        } catch { lastError = error.localizedDescription }
    }

    func openToday() {
        let url = URL(fileURLWithPath: expandTilde(outputPath))
            .appendingPathComponent(WorklogWriter.dayKey(Date()) + ".md")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            openOutputFolder()
        }
    }

    func openOutputFolder() {
        let url = URL(fileURLWithPath: expandTilde(outputPath))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func tick() async {
        guard !isPaused, !isWorking else { return }
        let dailyDue = await engine.shouldRunDailySummary()
        if dailyDue {
            if await performSummary() { await performDailySummary(automatic: true) }
            return
        }
        if let nextRun, Date() >= nextRun {
            await performSummary()
        }
    }

    @discardableResult
    private func performSummary(minutes: Int? = nil) async -> Bool {
        isWorking = true
        status = "Summarizing…"
        lastError = nil
        var succeeded = false
        do {
            await persistAndApply().value
            let result = try await engine.summarizeNow(minutesOverride: minutes)
            await refreshStatistics()
            lastRun = Date()
            status = result.outputURL == nil ? "No new activity" : "Worklog updated"
            succeeded = true
        } catch {
            status = "Summary failed"
            lastError = error.localizedDescription
        }
        isWorking = false
        scheduleNext(from: Date())
        return succeeded
    }

    private func performDailySummary(automatic: Bool = false) async {
        isWorking = true
        status = "Summarizing today…"
        lastError = nil
        do {
            await persistAndApply().value
            let url = try await engine.summarizeDay(markAutomatic: automatic)
            status = url == nil ? "No entries for today" : "Daily summary updated"
        } catch {
            status = "Daily summary failed"
            lastError = error.localizedDescription
        }
        isWorking = false
    }

    private func scheduleNext(from date: Date) {
        nextRun = date.addingTimeInterval(TimeInterval(max(1, intervalMinutes) * 60))
    }

    @discardableResult
    private func persistAndApply() -> Task<Void, Never> {
        let defaults = UserDefaults.standard
        defaults.set(selectedModel, forKey: "model")
        defaults.set(intervalMinutes, forKey: "intervalMinutes")
        defaults.set(summaryLookbackMinutes, forKey: "summaryLookbackMinutes")
        defaults.set(useScreenshots, forKey: "useScreenshots")
        defaults.set(outputPath, forKey: "outputPath")
        defaults.set(autoDailySummary, forKey: "autoDailySummary")

        var config = WorklogConfiguration()
        config.model = selectedModel
        config.intervalMinutes = max(1, intervalMinutes)
        config.summaryLookbackMinutes = max(1, summaryLookbackMinutes)
        config.useScreenshots = useScreenshots
        config.screenshotSelection = ScreenshotSelectionSettings(dynamic: dynamicScreenshots, minimum: minimumScreenshots, maximum: maximumScreenshots)
        config.screenshotSelection.save(to: defaults)
        config.outputDirectory = URL(fileURLWithPath: expandTilde(outputPath))
        config.autoDailySummary = autoDailySummary
        return Task { await engine.updateConfiguration(config) }
    }

    private func expandTilde(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }
}

struct SettingsView: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        Form {
            Picker("Ollama model", selection: $model.selectedModel) {
                if model.models.isEmpty {
                    Text(model.selectedModel).tag(model.selectedModel)
                } else {
                    ForEach(model.models, id: \.self) { Text($0).tag($0) }
                }
            }

            Stepper("Summary every \(model.intervalMinutes) minutes", value: $model.intervalMinutes, in: 5...120, step: 5)
            Toggle("Use representative screenshots with vision models", isOn: $model.useScreenshots)
            Toggle("Dynamic screenshot selection", isOn: $model.dynamicScreenshots)
                .disabled(!model.useScreenshots)
            Stepper("Preferred minimum: \(model.minimumScreenshots)", value: $model.minimumScreenshots, in: 0...model.maximumScreenshots)
            Stepper("Maximum screenshots: \(model.maximumScreenshots)", value: $model.maximumScreenshots, in: max(1, model.minimumScreenshots)...12)
            Text("Static or low-signal intervals may use fewer than the preferred minimum.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Output folder", text: $model.outputPath)
                .textFieldStyle(.roundedBorder)
            Button("Choose Output Folder…") { model.chooseOutputFolder() }
                .disabled(model.isWorking)

            Toggle("Create end-of-day summary around 11:50 PM", isOn: $model.autoDailySummary)

            HStack {
                Button("Save") { model.applySettings() }
                Button("Refresh Models") { Task { await model.refreshModels() } }
            }
        }
        .onChange(of: model.selectedModel) { _, _ in model.applySettings() }
    }
}
#else
import Foundation

@main
struct WorklogMenuBarUnsupported {
    static func main() {
        print("WorklogMenuBar requires macOS 15 or newer.")
    }
}
#endif

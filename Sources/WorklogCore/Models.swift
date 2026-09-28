import Foundation

public struct OCRObservation: Identifiable, Equatable, Sendable {
    public let id: String
    public let frameID: String
    public let startedAt: Date
    public let observedThrough: Date
    public let observationCount: Int
    public let displayName: String?
    public let text: String

    public init(
        id: String,
        frameID: String,
        startedAt: Date,
        observedThrough: Date,
        observationCount: Int,
        displayName: String?,
        text: String
    ) {
        self.id = id
        self.frameID = frameID
        self.startedAt = startedAt
        self.observedThrough = observedThrough
        self.observationCount = observationCount
        self.displayName = displayName
        self.text = text
    }
}

public struct SummaryResult: Sendable {
    public let start: Date
    public let end: Date
    public let rawObservationCount: Int
    public let retainedObservationCount: Int
    public let screenshotCount: Int
    public let markdown: String?
    public let outputURL: URL?

    public init(
        start: Date,
        end: Date,
        rawObservationCount: Int,
        retainedObservationCount: Int,
        screenshotCount: Int = 0,
        markdown: String?,
        outputURL: URL?
    ) {
        self.start = start
        self.end = end
        self.rawObservationCount = rawObservationCount
        self.retainedObservationCount = retainedObservationCount
        self.screenshotCount = screenshotCount
        self.markdown = markdown
        self.outputURL = outputURL
    }
}

public struct WorklogConfiguration: Sendable {
    public var model: String
    public var intervalMinutes: Int
    public var summaryLookbackMinutes: Int
    public var useScreenshots: Bool
    public var graceSeconds: Int
    public var outputDirectory: URL
    public var justNowDirectory: URL
    public var ollamaBaseURL: URL
    public var maxContextCharacters: Int
    public var diagnosticsDirectory: URL?
    public var databaseURL: URL = ActivityStore.defaultURL
    public var projectConfiguration = ProjectConfiguration()
    public var focusThresholdMinutes: Int = 25
    public var autoDailySummary: Bool

    public init(
        model: String = "gemma4:e4b",
        intervalMinutes: Int = 90,
        summaryLookbackMinutes: Int = 90,
        useScreenshots: Bool = true,
        graceSeconds: Int = 60,
        outputDirectory: URL = Self.defaultOutputDirectory,
        justNowDirectory: URL = Self.defaultJustNowDirectory,
        ollamaBaseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        maxContextCharacters: Int = 12_000,
        autoDailySummary: Bool = true
    ) {
        self.model = model
        self.intervalMinutes = intervalMinutes
        self.summaryLookbackMinutes = summaryLookbackMinutes
        self.useScreenshots = useScreenshots
        self.graceSeconds = graceSeconds
        self.outputDirectory = outputDirectory
        self.justNowDirectory = justNowDirectory
        self.ollamaBaseURL = ollamaBaseURL
        self.maxContextCharacters = maxContextCharacters
        self.autoDailySummary = autoDailySummary
    }

    public static var defaultJustNowDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JustNow", isDirectory: true)
    }

    public static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Worklogs", isDirectory: true)
    }
}

public enum WorklogError: LocalizedError {
    case justNowNotFound(URL)
    case justNowDatabaseMissing(String)
    case sqlite(String)
    case ollamaUnavailable(String)
    case modelNotInstalled(String)
    case emptyModelResponse
    case invalidSummaryResponse
    case invalidOutputDirectory(URL)
    case outputNotWritable(URL)

    public var errorDescription: String? {
        switch self {
        case .justNowNotFound(let url):
            return "JustNow data was not found at \(url.path). Run JustNow and let it capture some history first."
        case .justNowDatabaseMissing(let name):
            return "JustNow database \(name) is missing."
        case .sqlite(let message):
            return "SQLite error: \(message)"
        case .ollamaUnavailable(let message):
            return "Ollama is unavailable: \(message)"
        case .modelNotInstalled(let model):
            return "Ollama model '\(model)' is not installed."
        case .emptyModelResponse:
            return "Ollama returned an empty response."
        case .invalidSummaryResponse:
            return "Ollama did not return a valid activity diary. No entry was saved. Try summarizing again."
        case .invalidOutputDirectory(let url):
            return "Could not create output directory at \(url.path)."
        case .outputNotWritable(let url):
            return "Cannot save worklog at \(url.path). Choose the output folder again to grant access. If access is still denied, check Worklog in System Settings → Privacy & Security → Files and Folders, or choose a writable folder."
        }
    }
}

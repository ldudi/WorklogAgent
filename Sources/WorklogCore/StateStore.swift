import Foundation

public struct WorklogState: Codable, Sendable {
    public var lastProcessedAt: Date?
    public var lastDailySummaryDay: String?

    public init(lastProcessedAt: Date? = nil, lastDailySummaryDay: String? = nil) {
        self.lastProcessedAt = lastProcessedAt
        self.lastDailySummaryDay = lastDailySummaryDay
    }
}

public actor StateStore {
    public let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/WorklogAgent", isDirectory: true)
            self.url = base.appendingPathComponent("state.json")
        }
    }

    public func load() -> WorklogState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WorklogState.self, from: data) else {
            return WorklogState()
        }
        return state
    }

    public func save(_ state: WorklogState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

import Foundation
import CSQLite

public struct JustNowReader {
    public let directory: URL

    public init(directory: URL = WorklogConfiguration.defaultJustNowDirectory) {
        self.directory = directory
    }

    public var framesDatabaseURL: URL { directory.appendingPathComponent("frames.sqlite") }
    public var textDatabaseURL: URL { directory.appendingPathComponent("text_cache.sqlite") }

    public func validate() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorklogError.justNowNotFound(directory)
        }
        guard FileManager.default.fileExists(atPath: framesDatabaseURL.path) else {
            throw WorklogError.justNowDatabaseMissing("frames.sqlite")
        }
        guard FileManager.default.fileExists(atPath: textDatabaseURL.path) else {
            throw WorklogError.justNowDatabaseMissing("text_cache.sqlite")
        }
    }

    public func observations(from start: Date, to end: Date) throws -> [OCRObservation] {
        try validate()
        let spans = try readSpans(from: start, to: end)
        guard !spans.isEmpty else { return [] }
        let textByFrame = try readTexts(frameIDs: Array(Set(spans.map(\.frameID))))

        return spans.compactMap { span in
            guard let text = textByFrame[span.frameID], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return OCRObservation(
                id: span.id,
                frameID: span.frameID,
                startedAt: max(start, span.startedAt),
                observedThrough: min(end, span.observedThrough),
                observationCount: span.observationCount,
                displayName: span.displayName,
                text: text
            )
        }
    }

    private struct Span {
        let id: String
        let frameID: String
        let startedAt: Date
        let observedThrough: Date
        let observationCount: Int
        let displayName: String?
    }

    private func readSpans(from start: Date, to end: Date) throws -> [Span] {
        let db = try SQLiteReadConnection(url: framesDatabaseURL)
        let statement = try db.prepare(
            """
            SELECT id, frame_id, started_at, observed_through_at, observation_count, display_name
            FROM frame_spans
            WHERE observed_through_at >= ? AND started_at <= ?
            ORDER BY started_at ASC, sequence ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_double(statement, 1, start.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, end.timeIntervalSince1970) == SQLITE_OK else {
            throw WorklogError.sqlite(db.errorMessage())
        }

        var result: [Span] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw WorklogError.sqlite(db.errorMessage()) }
            guard let id = sqliteText(statement, 0), let frameID = sqliteText(statement, 1) else { continue }
            result.append(
                Span(
                    id: id,
                    frameID: frameID,
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    observedThrough: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    observationCount: Int(sqlite3_column_int64(statement, 4)),
                    displayName: sqliteText(statement, 5)
                )
            )
        }
        return result
    }

    private func readTexts(frameIDs: [String]) throws -> [String: String] {
        guard !frameIDs.isEmpty else { return [:] }
        let db = try SQLiteReadConnection(url: textDatabaseURL)
        var result: [String: String] = [:]

        for chunkStart in stride(from: 0, to: frameIDs.count, by: 300) {
            let chunk = Array(frameIDs[chunkStart..<min(chunkStart + 300, frameIDs.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let statement = try db.prepare(
                "SELECT frame_id, text FROM frame_text WHERE frame_id IN (\(placeholders));"
            )
            defer { sqlite3_finalize(statement) }

            for (offset, frameID) in chunk.enumerated() {
                guard bindText(frameID, to: statement, index: Int32(offset + 1)) else {
                    throw WorklogError.sqlite(db.errorMessage())
                }
            }

            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw WorklogError.sqlite(db.errorMessage()) }
                if let frameID = sqliteText(statement, 0), let text = sqliteText(statement, 1) {
                    result[frameID] = text
                }
            }
        }
        return result
    }
}

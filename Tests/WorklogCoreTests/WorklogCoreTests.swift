import XCTest
@testable import WorklogCore
import CSQLite

final class WorklogCoreTests: XCTestCase {
    func testScreenshotsUseReadOnlyMetadataAndRejectPathsOutsideFramesFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let frames = root.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("frames.sqlite")
        try createFramesDB(at: databaseURL)
        try Data([1, 2, 3]).write(to: frames.appendingPathComponent("screen.jpg"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE frames (id TEXT, filename TEXT, perceptual_hash BLOB); INSERT INTO frames VALUES ('frame-1','screen.jpg',X'0000000000000000');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: databaseURL)
        let reader = JustNowReader(directory: root)
        let rows = try reader.screenshotCandidates(from: Date(timeIntervalSince1970: 1000), to: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.url, frames.appendingPathComponent("screen.jpg"))
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        try Data([4]).write(to: root.appendingPathComponent("outside.jpg"))
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE frames SET filename='../outside.jpg';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(try reader.screenshotCandidates(from: Date(timeIntervalSince1970: 1000), to: Date(timeIntervalSince1970: 2000)).count, 0)
    }

    func testManualLookbackIsInspectionAndAutomaticUsesOwnedCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try createFramesDB(at: root.appendingPathComponent("frames.sqlite"))
        try createTextDB(at: root.appendingPathComponent("text_cache.sqlite"))
        let now = Date(timeIntervalSince1970: 100_000)
        let store = StateStore(url: root.appendingPathComponent("state.json"))
        let checkpoint = now.addingTimeInterval(-600)
        try await store.save(WorklogState(lastProcessedAt: checkpoint))
        var configuration = WorklogConfiguration(useScreenshots: false, graceSeconds: 0, outputDirectory: root.appendingPathComponent("output"), justNowDirectory: root)
        configuration.databaseURL = root.appendingPathComponent("owned.sqlite")
        let engine = WorklogEngine(configuration: configuration, stateStore: store)
        let manual = try await engine.summarizeNow(minutesOverride: 90, now: now)
        XCTAssertEqual(manual.start, now.addingTimeInterval(-5400))
        XCTAssertEqual(manual.end, now)
        let afterManual = await store.load()
        XCTAssertEqual(afterManual.lastProcessedAt, checkpoint)
        let automatic = try await engine.summarizeNow(now: now)
        XCTAssertEqual(automatic.start, now.addingTimeInterval(-5400))
        let afterAutomatic = await store.load()
        XCTAssertEqual(afterAutomatic.lastProcessedAt, checkpoint) // Legacy JSON is no longer canonical.
        let owned = try ActivityStore(url: configuration.databaseURL)
        let ownedCheckpoint = try await owned.checkpoint()
        XCTAssertEqual(ownedCheckpoint, now)
        let next = try await engine.summarizeNow(now: now.addingTimeInterval(600))
        XCTAssertEqual(next.start, now)
        XCTAssertEqual(next.end, now.addingTimeInterval(600))
    }

    func testWriteAccessCheckPreservesExistingWorklog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = WorklogWriter(outputDirectory: root)
        let date = Date()
        try writer.appendIntervalSummary("Existing entry", start: date, end: date)
        let before = try Data(contentsOf: writer.worklogURL(for: date))

        try writer.validateWriteAccess(for: date)

        XCTAssertEqual(try Data(contentsOf: writer.worklogURL(for: date)), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [writer.worklogURL(for: date).lastPathComponent])
    }

    func testWriteAccessCheckCreatesFolderWithoutCreatingWorklog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try WorklogWriter(outputDirectory: root).validateWriteAccess(for: Date())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testWriteAccessCheckRejectsReadOnlyWorklog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = WorklogWriter(outputDirectory: root)
        let date = Date()
        let url = writer.worklogURL(for: date)
        try "Keep this entry".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertThrowsError(try writer.validateWriteAccess(for: date)) { error in
            guard case WorklogError.outputNotWritable(let failedURL) = error else {
                return XCTFail("Expected an actionable output access error")
            }
            XCTAssertEqual(failedURL, url)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Keep this entry")
    }

    func testSummaryChecksWriteAccessBeforeReadingScreensOrCallingOllama() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "Not a folder".write(to: root, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = WorklogConfiguration(outputDirectory: root, justNowDirectory: root)
        configuration.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("owned.sqlite")
        defer { try? FileManager.default.removeItem(at: configuration.databaseURL.deletingLastPathComponent()) }
        let engine = WorklogEngine(configuration: configuration)
        do {
            _ = try await engine.summarizeInterval(start: Date().addingTimeInterval(-60), end: Date())
            XCTFail("Expected output preflight failure")
        } catch {
            guard case WorklogError.outputNotWritable = error else {
                return XCTFail("Expected output access failure before reading JustNow")
            }
        }
    }

    func testRedactsCommonSecrets() {
        let input = """
        API_KEY=super-secret-value
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz
        token: ghp_abcdefghijklmnopqrstuvwxyz123456
        """
        let output = SecretRedactor().redact(input)
        XCTAssertFalse(output.contains("super-secret-value"))
        XCTAssertFalse(output.contains("abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(output.contains("[REDACTED"))
    }

    func testDeduplicatesHighlySimilarAdjacentOCR() {
        let base = Date()
        let a = OCRObservation(
            id: "1", frameID: "a", startedAt: base, observedThrough: base.addingTimeInterval(3),
            observationCount: 1, displayName: "Display 1",
            text: "Xcode ExampleProject implement example feature tests passed"
        )
        let b = OCRObservation(
            id: "2", frameID: "b", startedAt: base.addingTimeInterval(5), observedThrough: base.addingTimeInterval(8),
            observationCount: 1, displayName: "Display 1",
            text: "Xcode ExampleProject implement example feature tests passed"
        )
        let c = OCRObservation(
            id: "3", frameID: "c", startedAt: base.addingTimeInterval(10), observedThrough: base.addingTimeInterval(12),
            observationCount: 1, displayName: "Display 1",
            text: "Terminal swift test 246 tests passed zero failures"
        )

        let result = OCRDeduplicator().deduplicate([a, b, c])
        XCTAssertEqual(result.map(\.id), ["1", "3"])
    }

    func testJustNowReaderJoinsSpanMetadataToOCR() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try createFramesDB(at: root.appendingPathComponent("frames.sqlite"))
        try createTextDB(at: root.appendingPathComponent("text_cache.sqlite"))

        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let rows = try JustNowReader(directory: root).observations(from: start, to: end)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.displayName, "External Display")
        XCTAssertEqual(rows.first?.text, "Xcode WorklogEngine summarizeNow")
    }

    private func createFramesDB(at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE frame_spans (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            frame_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            started_at REAL NOT NULL,
            observed_through_at REAL NOT NULL,
            observation_count INTEGER NOT NULL,
            display_id TEXT,
            display_name TEXT
        );
        INSERT INTO frame_spans(id, frame_id, session_id, started_at, observed_through_at, observation_count, display_name)
        VALUES ('span-1', 'frame-1', 'session-1', 1200, 1210, 3, 'External Display');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func createTextDB(at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE frame_text (frame_id TEXT PRIMARY KEY, timestamp REAL NOT NULL, text TEXT NOT NULL);
        INSERT INTO frame_text(frame_id, timestamp, text)
        VALUES ('frame-1', 1210, 'Xcode WorklogEngine summarizeNow');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}

import XCTest
import Foundation
import CSQLite
@testable import WorklogCore

final class OllamaDiaryTests: XCTestCase {
    private func client() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiaryStubProtocol.self]
        return OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!, session: URLSession(configuration: configuration))
    }

    func testGenerateCarriesImagesTaskAndContinuityInOnePrompt() async throws {
        let marker = UUID().uuidString
        let text = try await client().summarizeInterval(model: "gemma4:e4b", context: marker,
            start: Date(), end: Date(), images: ["test-image-base64"], previousSummary: "Earlier WorklogAgent investigation")
        XCTAssertTrue(text.contains("### Activity"))
        let requests = DiaryStubProtocol.store.requests()
        let request = try XCTUnwrap(requests.last { $0.url?.lastPathComponent == "generate" && $0.prompt.contains(marker) })
        XCTAssertEqual(request.images, ["test-image-base64"])
        XCTAssertTrue(request.prompt.contains("Reconstruct what the computer user"))
        XCTAssertTrue(request.prompt.contains("Earlier WorklogAgent investigation"))
        XCTAssertEqual(request.format, "json")
        XCTAssertFalse(request.stream)
    }

    func testVisionCapabilityDetectionFallsBackForTextOnlyModels() async throws {
        let vision = try await client().supportsVision(model: "gemma4:e4b")
        let textOnly = try await client().supportsVision(model: "text-only")
        XCTAssertTrue(vision)
        XCTAssertFalse(textOnly)
    }

    func testEachScreenshotIsRecognizedIndependently() async throws {
        let facts = try await client().describeScreenshot(model: "gemma4:e4b", image: "one-frame-only")
        XCTAssertTrue(facts.contains("Application: ChatGPT"))
        XCTAssertTrue(facts.contains("idle home page"))
        let request = try XCTUnwrap(DiaryStubProtocol.store.requests().last { $0.images == ["one-frame-only"] })
        XCTAssertTrue(request.prompt.contains("from this ONE computer screenshot"))
    }

    func testStructuredJSONRepairsOnceThenAcceptsValidRecords() async throws {
        let start = Date(timeIntervalSince1970: 1000)
        let marker = "force-repair-response " + UUID().uuidString
        let evidence = [ActivityEvidence(id: "test-evidence", timestamp: start, excerpt: marker)]
        let rows = try await client().reconstructActivities(model: "gemma4:e4b", evidence: evidence, start: start, end: start.addingTimeInterval(1800), projects: ProjectConfiguration())
        XCTAssertEqual(rows.first?.category, .coding)
        let requests = DiaryStubProtocol.store.requests().filter { $0.url?.lastPathComponent == "generate" && $0.prompt.contains(marker) }
        XCTAssertEqual(requests.count, 2); XCTAssertTrue(requests.last?.prompt.contains("REPAIR:") ?? false)
        XCTAssertTrue(requests.allSatisfy(\.structuredFormat))
    }

    func testMalformedStructuredJSONStoresSafeFallbackAfterTwoAttempts() async throws {
        let start = Date(timeIntervalSince1970: 1000)
        let marker = "force-invalid-response " + UUID().uuidString
        let evidence = [ActivityEvidence(id: "test-evidence", timestamp: start, excerpt: marker)]
        let rows = try await client().reconstructActivities(model: "gemma4:e4b", evidence: evidence, start: start, end: start.addingTimeInterval(1800), projects: ProjectConfiguration())
        XCTAssertEqual(rows.first?.source, .fallback); XCTAssertEqual(rows.first?.intent, .unknown)
        XCTAssertEqual(rows.first?.evidenceIDs, ["test-evidence"])
        let requests = DiaryStubProtocol.store.requests().filter { $0.url?.lastPathComponent == "generate" && $0.prompt.contains(marker) }
        XCTAssertEqual(requests.count, 2)
    }

    func testEnginePersistsValidatedFactsAndReplayDoesNotCallModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("frames.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE frame_spans(sequence INTEGER PRIMARY KEY,id TEXT,frame_id TEXT,started_at REAL,observed_through_at REAL,observation_count INT,display_name TEXT); INSERT INTO frame_spans VALUES(1,'s','f',1000,2800,1,'External');", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("text_cache.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE frame_text(frame_id TEXT,text TEXT); INSERT INTO frame_text VALUES('f','Xcode editing Swift source code');", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        var configuration = WorklogConfiguration(useScreenshots: false, outputDirectory: root.appendingPathComponent("reports"), justNowDirectory: root)
        configuration.databaseURL = root.appendingPathComponent("owned.sqlite")
        let engine = WorklogEngine(configuration: configuration, ollamaClient: client())
        let start = Date(timeIntervalSince1970: 1000), end = Date(timeIntervalSince1970: 2800)
        let first = try await engine.summarizeInterval(start: start, end: end)
        XCTAssertNotNil(first.outputURL)
        let before = DiaryStubProtocol.store.requests().count
        let replay = try await engine.summarizeInterval(start: start, end: end)
        XCTAssertEqual(replay.outputURL, first.outputURL); XCTAssertEqual(DiaryStubProtocol.store.requests().count, before)
        let store = try ActivityStore(url: configuration.databaseURL)
        let records = try await store.records(from: start, to: end)
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.category, .coding)
        let checkpoint = try await store.checkpoint(); XCTAssertEqual(checkpoint, end)
    }

    func testRemoteOllamaEndpointRejectedBeforeRequest() async {
        do {
            _ = try await OllamaClient(baseURL: URL(string: "https://example.com")!).listModels()
            XCTFail("Only local inference is allowed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("local loopback")) }
    }

    func testMalformedAssistantReplyIsRejected() async {
        do {
            _ = try await client().summarizeInterval(model: "gemma4:e4b", context: "force-invalid-response", start: Date(), end: Date())
            XCTFail("A clarification response must not become a diary")
        } catch {
            guard case WorklogError.invalidSummaryResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
    func testEngineVisionRequestsRespectDynamicSelectionAndPersistMetrics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let frames = root.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Valid PNG fixture; encoding is exercised through ImageIO, without Ollama.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="))
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("frames.sqlite").path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "CREATE TABLE frame_spans(sequence INTEGER PRIMARY KEY,id TEXT,frame_id TEXT,started_at REAL,observed_through_at REAL,observation_count INT,display_name TEXT); CREATE TABLE frames(id TEXT,filename TEXT,perceptual_hash BLOB);", nil, nil, nil), SQLITE_OK)
        let texts = ["Editor implementing orchard apple sorting algorithm", "Terminal compiling banana parser library process", "Terminal all tests passed build succeeded", "Terminal all tests passed build succeeded"]
        for index in texts.indices {
            try png.write(to: frames.appendingPathComponent("f\(index).png"))
            XCTAssertEqual(sqlite3_exec(pointer, "INSERT INTO frames VALUES('f\(index)','f\(index).png',NULL); INSERT INTO frame_spans VALUES(\(index),'s\(index)','f\(index)',\(1000 + index * 60),\(1059 + index * 60),1,'External');", nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(pointer)
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("text_cache.sqlite").path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "CREATE TABLE frame_text(frame_id TEXT,text TEXT);", nil, nil, nil), SQLITE_OK)
        for index in texts.indices {
            XCTAssertEqual(sqlite3_exec(pointer, "INSERT INTO frame_text VALUES('f\(index)','\(texts[index])');", nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(pointer)
        var config = WorklogConfiguration(outputDirectory: root.appendingPathComponent("reports"), justNowDirectory: root)
        config.databaseURL = root.appendingPathComponent("owned.sqlite")
        config.screenshotSelection = .init(maximum: 3)
        let engine = WorklogEngine(configuration: config, ollamaClient: client())
        let start = Date(timeIntervalSince1970: 1000), end = Date(timeIntervalSince1970: 2800)
        let before = DiaryStubProtocol.store.requests().count
        let result = try await engine.summarizeInterval(start: start, end: end)
        let requests = Array(DiaryStubProtocol.store.requests().dropFirst(before))
        let vision = requests.filter { $0.prompt.contains("EXTRACT SCREEN FACTS") }
        XCTAssertEqual(result.visualSelection?.selectedScreenshotCount, 3)
        XCTAssertEqual(result.screenshotCount, 3)
        XCTAssertEqual(vision.count, 3)
        XCTAssertTrue(vision.allSatisfy { $0.images.count == 1 })
        XCTAssertTrue(requests.filter { $0.prompt.contains("PRIMARY activity timeline") }.allSatisfy { $0.images.isEmpty })
        XCTAssertGreaterThan(result.visualSelection?.encodedImagePayloadBytes ?? 0, 0)
        XCTAssertEqual(result.visualSelection?.requestedImageCount, 3)
        let store = try ActivityStore(url: config.databaseURL)
        let stored = try await store.visualSelection(start: start, end: end)
        XCTAssertEqual(stored, result.visualSelection)
        let diagnostic = try await engine.inspect(start: start, end: end)
        XCTAssertTrue(diagnostic.contains("Selected screenshots: 3"))
        XCTAssertFalse(diagnostic.contains("orchard"))
        let checkpoint = try await store.checkpoint()
        _ = try await engine.summarizeInterval(start: start, end: end, inspectionOnly: true)
        let afterInspection = try await store.checkpoint()
        XCTAssertEqual(afterInspection, checkpoint)
        let metadataAfterInspection = try await store.visualSelection(start: start, end: end)
        XCTAssertEqual(metadataAfterInspection, stored)
    }

}

private struct RecordedRequest {
    let url: URL?
    let prompt: String
    let images: [String]
    let format: String
    let structuredFormat: Bool
    let stream: Bool
}

/// URLProtocol callbacks can arrive on different threads; all shared state is locked.
private final class RequestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RecordedRequest] = []
    func record(_ value: RecordedRequest) { lock.withLock { values.append(value) } }
    func requests() -> [RecordedRequest] { lock.withLock { values } }
}

private final class DiaryStubProtocol: URLProtocol {
    static let store = RequestStore()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let prompt = body["prompt"] as? String ?? ""
        Self.store.record(RecordedRequest(url: request.url, prompt: prompt, images: body["images"] as? [String] ?? [],
                                         format: body["format"] as? String ?? "", structuredFormat: (body["format"] as? [String: Any])?["type"] as? String == "object", stream: body["stream"] as? Bool ?? true))
        let result: [String: Any]
        switch request.url?.lastPathComponent {
        case "tags": result = ["models": [["name": "gemma4:e4b"]]]
        case "show": result = ["capabilities": body["model"] as? String == "text-only" ? ["completion"] : ["completion", "vision"]]
        default:
            let diary = #"{"activity":["Reviewed WorklogAgent."],"technicalWork":[],"outcomes":[],"problems":[],"nextContext":[]}"#
            let facts = #"{"application":"ChatGPT","visibleText":["chatgpt.com"],"activity":"idle home page"}"#
            let evidenceID = prompt.components(separatedBy: "\n").compactMap { line -> String? in
                guard line.hasPrefix("{"), let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return object["id"] as? String
            }.first ?? "test-evidence"
            let activity = #"{"activities":[{"startOffset":0,"endOffset":1800,"title":"Implement feature","summary":"Edited Swift source","category":"coding","intent":"BUILD","project":null,"confidence":0.8,"classificationConfidence":0.8,"backgroundContext":"","entities":[],"evidenceIDs":["test-evidence"],"facts":[]}]}"#.replacingOccurrences(of: "test-evidence", with: evidenceID)
            let repairNeeded = prompt.contains("force-repair-response") && !prompt.contains("REPAIR:")
            result = ["response": (prompt.contains("force-invalid-response") || repairNeeded) ? "Please clarify your question." :
                (prompt.contains("EXTRACT SCREEN FACTS") ? facts : (prompt.contains("PRIMARY activity timeline") ? activity : diary))]
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
              let responseData = try? JSONSerialization.data(withJSONObject: result) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

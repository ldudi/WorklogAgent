import XCTest
@testable import WorklogCore

final class ActivityDiaryTests: XCTestCase {
    func testScreenshotSelectionRemovesStaticDuplicatesAndPreservesBothDisplays() {
        let rows = (0..<20).flatMap { index -> [ScreenshotEvidence] in
            [ScreenshotEvidence(id: "static-\(index)", startedAt: Date(timeIntervalSince1970: Double(index)),
                displayName: "External", url: URL(fileURLWithPath: "/tmp/static.jpg"), perceptualHash: Data(repeating: 0, count: 8)),
             ScreenshotEvidence(id: "changing-\(index)", startedAt: Date(timeIntervalSince1970: Double(index)),
                displayName: "Built-in", url: URL(fileURLWithPath: "/tmp/changing.jpg"), perceptualHash: Data(repeating: index.isMultiple(of: 2) ? 0xff : 0, count: 8))]
        }
        let result = VisualEvidenceSampler().select(images: rows, observations: [],
            start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(result.selected.count, 1) // No OCR: bounded visual fallback.
        XCTAssertEqual(result.metadata.distinctClusterCount, 1)
    }

    func testContinuityUsesAcceptedDiaryAndExcludesDailySummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = WorklogWriter(outputDirectory: root)
        let date = Date()
        try writer.appendIntervalSummary("Could you clarify your question?", start: date, end: date)
        XCTAssertEqual(try writer.previousDiary(before: date), "")
        try writer.appendIntervalSummary("### Activity\n- Investigated WorklogAgent saving.\n### Next context\n- Check the next summary.", start: date, end: date)
        try writer.appendDailySummary("## Daily Summary\n### Activity\n- Daily-only text", for: date)
        let previous = try writer.previousDiary(before: date)
        XCTAssertTrue(previous.contains("Investigated WorklogAgent"))
        XCTAssertFalse(previous.contains("Daily-only text"))
        let prompt = WorklogPrompts.interval(context: "Current screenshot", start: date, end: date, previousSummary: previous)
        XCTAssertTrue(prompt.contains("historical context only"))
        XCTAssertTrue(prompt.contains("Do not repeat historical outcomes"))
    }

    func testGenericEvidenceComplaintsAreOmittedFromDiary() throws {
        let response = #"{"activity":["Watched YouTube music videos."],"technicalWork":[],"outcomes":[],"problems":["The provided evidence is heavily fragmented and contains unreadable characters."],"nextContext":[]}"#
        let text = try WorklogDiary.markdown(from: response)
        XCTAssertTrue(text.contains("YouTube"))
        XCTAssertFalse(text.contains("fragmented"))
        XCTAssertFalse(text.contains("Problems / discoveries"))
    }

    func testRepeatedActivitiesAndEmptySectionPlaceholdersAreRemoved() throws {
        let response = #"{"activity":["Watching YouTube videos related to music and Bollywood songs.","Browsing YouTube for new Bollywood songs."],"technicalWork":[],"outcomes":["[]"],"problems":["[]"],"nextContext":["No specific unfinished task is visible."]}"#
        let text = try WorklogDiary.markdown(from: response)
        XCTAssertEqual(text.components(separatedBy: "YouTube").count, 2)
        XCTAssertFalse(text.contains("### Outcomes"))
        XCTAssertFalse(text.contains("### Next context"))
    }

    private func observation(_ text: String, at second: Int = 0, display: String = "External") -> OCRObservation {
        OCRObservation(id: "\(display)-\(second)", frameID: "frame-\(second)",
                       startedAt: Date(timeIntervalSince1970: Double(second)),
                       observedThrough: Date(timeIntervalSince1970: Double(second + 5)),
                       observationCount: 1, displayName: display, text: text)
    }

    func testGarbledLinesAreRemovedAndProgrammingEvidenceSurvives() {
        let raw = observation("""
        O • 8 MonSop28*21PM...
        cthGpr K•Th••n SlwhwNt&thdv•
        ReferralCodeEntryView
        swift test
        246 tests passed
        YouTube
        API_KEY=secret-value-12345
        """)
        let rows = ActivityPreprocessor().clean([raw])
        let text = rows.first?.text ?? ""
        XCTAssertFalse(text.contains("cthGpr"))
        XCTAssertFalse(text.contains("MonSop"))
        XCTAssertFalse(text.contains("secret-value-12345"))
        for value in ["ReferralCodeEntryView", "swift test", "246 tests passed", "YouTube"] {
            XCTAssertTrue(text.contains(value), value)
        }
    }

    func testPersistentMenusAreRemovedWithoutRemovingProjectNames() {
        let raw = (0..<6).map { observation("File Edit View Window Help\nWorklogAgent\nOllamaClient.swift\nswift test", at: $0 * 10) }
        let cleaned = ActivityPreprocessor().clean(raw)
        XCTAssertEqual(cleaned.count, 6)
        XCTAssertFalse(cleaned[0].text.contains("File Edit"))
        XCTAssertTrue(cleaned[0].text.contains("WorklogAgent"))
    }

    func testClusteringRetainsDurationAndBothDisplaysInChronologicalOrder() {
        let rows = [observation("YouTube Gully Boy trailer", at: 40, display: "Built-in"),
                    observation("Xcode WorklogAgent OllamaClient.swift", at: 10),
                    observation("Xcode WorklogAgent OllamaClient.swift", at: 20)]
        let clustered = OCRDeduplicator().deduplicate(rows)
        XCTAssertEqual(clustered.count, 2)
        XCTAssertEqual(clustered.first?.startedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(clustered.first?.observedThrough, Date(timeIntervalSince1970: 25))
        XCTAssertEqual(clustered.first?.observationCount, 2)
        XCTAssertEqual(Set(clustered.compactMap(\.displayName)), ["External", "Built-in"])
    }

    func testSignificantChangeAndNewTestOutcomeRemainSeparate() {
        let base = "Xcode WorklogAgent OllamaClient.swift source editor configuration swift terminal test documentation " + (0..<30).map { "symbol\($0)" }.joined(separator: " ")
        let rows = [observation(base + "\n246 tests passed", at: 0),
                    observation(base + "\n247 tests passed", at: 10),
                    observation("YouTube Gully Boy movie trailer", at: 20)]
        XCTAssertEqual(OCRDeduplicator().deduplicate(rows).count, 3)
    }

    func testContextIsBoundedAndSamplesAcrossWholeIntervalAndBothDisplays() {
        let rows = (0..<200).map { observation("WorklogAgent marker\($0)\n" + String(repeating: "Swift test output ", count: 100), at: $0 * 10, display: $0.isMultiple(of: 2) ? "External" : "Built-in") }
        let context = ContextBuilder(maxCharacters: 4000).build(from: rows)
        XCTAssertLessThanOrEqual(context.count, 4000)
        XCTAssertTrue(context.contains("marker0"))
        XCTAssertTrue(context.contains("marker199"))
        XCTAssertTrue(context.contains("External"))
        XCTAssertTrue(context.contains("Built-in"))
        XCTAssertEqual(ContextBuilder(maxCharacters: 0).build(from: rows), "")
    }

    func testEmptyOrNoiseOnlyEvidenceProducesNoContext() {
        let rows = ActivityPreprocessor().clean([observation("•••••• • 8 cthGpr K•Th••n")])
        XCTAssertEqual(rows.count, 0)
        XCTAssertEqual(ContextBuilder().build(from: rows), "")
    }

    func testDiaryResponseRejectsClarificationAndAllowsVideoActivityOnly() throws {
        XCTAssertThrowsError(try WorklogDiary.markdown(from: "Could you please clarify what you would like help with?"))
        XCTAssertThrowsError(try WorklogDiary.markdown(from: #"{"activity":["Could you please clarify?"],"technicalWork":[],"outcomes":[],"problems":[],"nextContext":[]}"#))
        let response = #"{"activity":["Browsed YouTube and watched a movie trailer."],"technicalWork":[],"outcomes":[],"problems":[],"nextContext":[]}"#
        let rendered = try WorklogDiary.markdown(from: response)
        XCTAssertTrue(rendered.contains("### Activity"))
        XCTAssertFalse(rendered.contains("Technical work"))
        XCTAssertFalse(rendered.contains("Outcomes"))
        let prompt = WorklogPrompts.interval(context: "YouTube Gully Boy", start: Date(), end: Date())
        XCTAssertTrue(prompt.contains("Never ask questions"))
        XCTAssertTrue(prompt.contains("It does NOT support engineering achievements"))
    }

    func testDiaryRendersTechnicalFactsAndRedactsModelOutput() throws {
        let response = #"{"activity":["Reviewed WorklogAgent in Xcode."],"technicalWork":["Ran swift test in Terminal."],"outcomes":["246 tests passed."],"problems":["API_KEY=leaked-secret-value"],"nextContext":[]}"#
        let text = try WorklogDiary.markdown(from: response)
        XCTAssertTrue(text.contains("### Technical work"))
        XCTAssertTrue(text.contains("246 tests passed"))
        XCTAssertFalse(text.contains("leaked-secret-value"))
    }

    func testDailySummaryRefreshIncludesNewEntriesAndPreservesOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = WorklogWriter(outputDirectory: root)
        let date = Date()
        try writer.appendIntervalSummary("### Activity\n- First task", start: date, end: date)
        try writer.appendDailySummary("## Daily Summary\n- Old daily summary", for: date)
        try writer.appendIntervalSummary("### Activity\n- Second task", start: date, end: date)
        let beforeRefresh = try XCTUnwrap(writer.readWorklog(for: date))
        let entries = writer.intervalEntries(in: beforeRefresh)
        XCTAssertTrue(entries.contains("First task"))
        XCTAssertTrue(entries.contains("Second task"))
        XCTAssertFalse(entries.contains("Old daily summary"))
        try writer.appendDailySummary("## Daily Summary\n- Combined tasks", for: date)
        let after = try XCTUnwrap(writer.readWorklog(for: date))
        XCTAssertEqual(after.components(separatedBy: WorklogWriter.dailyMarker).count, 2)
        XCTAssertFalse(after.contains("Old daily summary"))
        XCTAssertTrue(after.contains("Combined tasks"))
        XCTAssertEqual(writer.intervalEntries(in: after).trimmingCharacters(in: .whitespacesAndNewlines), entries.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testDailyContextRetainsEarlyAndLateIntervalsWithinBudget() {
        let markdown = "# Worklog\n\n" + (0..<40).map { "## interval\($0)\n### Activity\n- " + String(repeating: "task ", count: 100) }.joined(separator: "\n")
        let context = DailyContextBuilder(maxCharacters: 4000).build(from: markdown)
        XCTAssertLessThanOrEqual(context.count, 4000)
        XCTAssertTrue(context.contains("interval0"))
        XCTAssertTrue(context.contains("interval39"))
    }
}

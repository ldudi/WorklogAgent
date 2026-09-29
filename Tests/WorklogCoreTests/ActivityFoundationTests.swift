import XCTest
import CSQLite
@testable import WorklogCore

final class ActivityFoundationTests: XCTestCase {
    private var root: URL!
    private let start = Date(timeIntervalSince1970: 1_790_553_600)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func store() throws -> ActivityStore { try ActivityStore(url: root.appendingPathComponent("activity.sqlite")) }
    private func evidence(display: String = "External", id: String = "e1") -> ActivityEvidence {
        ActivityEvidence(id: id, timestamp: start, display: display, excerpt: "Xcode ExampleProject swift test 27 tests passed")
    }
    private func record(offset: Double = 0, duration: Double = 1800, category: ActivityCategory = .coding,
                        intent: ActivityIntent = .build, title: String = "Implement feature") -> ActivityRecord {
        let from = start.addingTimeInterval(offset), to = from.addingTimeInterval(duration)
        var item = ActivityReconstruction().fallback(start: from, end: to, evidenceIDs: ["e1"])
        item.title = title; item.category = category; item.intent = intent; item.confidence = 0.8
        item.classificationConfidence = 0.8; item.source = .justNow
        return item
    }
    private func save(_ record: ActivityRecord, store: ActivityStore) async throws {
        try await store.persist(start: record.start, end: record.end, records: [record], evidence: [evidence()])
    }
    private func json(category: String = "coding", intent: String = "BUILD", confidence: String = "0.8", facts: String = "[]", evidenceIDs: String = "[\"e1\"]", offset: Double = 0, end: Double = 1800) -> String {
        """
        {"activities":[{"startOffset":\(offset),"endOffset":\(end),"title":"Implement feature","summary":"Edited source","category":"\(category)","intent":"\(intent)","project":"InventedProject","confidence":\(confidence),"classificationConfidence":0.8,"backgroundContext":"Music on second display","entities":[{"kind":"technology","name":"Swift"}],"evidenceIDs":\(evidenceIDs),"facts":\(facts)}]}
        """
    }
    private func decode(_ json: String, projects: ProjectConfiguration = ProjectConfiguration()) throws -> [ActivityRecord] {
        try ActivityReconstruction().decode(json, start: start, end: start.addingTimeInterval(1800), evidence: [evidence()], projects: projects)
    }
    func testSchemaCreationAndReopening() async throws {
        let first = try store(); let version = try await first.version(); XCTAssertEqual(version, 4)
        try await save(record(), store: first)
        let reopened = try store(); let rows = try await reopened.search(ActivitySearch(from: start, to: start.addingTimeInterval(3600)))
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.duration, 1800)
    }
    func testMigrationPreservesActivityAndBacksUpDatabase() async throws {
        let first = try store(); try await save(record(), store: first)
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("activity.sqlite").path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "ALTER TABLE processing_windows DROP COLUMN visual_selection; DROP TABLE corrections; DROP TABLE activity_fts; ALTER TABLE evidence DROP COLUMN source_reference; ALTER TABLE evidence DROP COLUMN provenance; PRAGMA user_version=1;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(pointer)
        let migrated = try store(); let version = try await migrated.version(); XCTAssertEqual(version, 4)
        let found = try await migrated.search(ActivitySearch(from: start, to: start.addingTimeInterval(3600), text: "feature"))
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".backup") })
    }
    func testFutureSchemaIsRejected() async throws {
        _ = try store()
        var pointer: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("activity.sqlite").path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK); sqlite3_close(pointer)
        XCTAssertThrowsError(try store())
    }
    func testExactIntervalIsIdempotent() async throws {
        let db = try store(), item = record()
        try await save(item, store: db)
        let inserted = try await db.persist(start: item.start, end: item.end, records: [item], evidence: [evidence()])
        XCTAssertFalse(inserted)
        let rows = try await db.records(from: start, to: start.addingTimeInterval(3600)); XCTAssertEqual(rows.count, 1)
    }
    func testOverlappingWindowRollsBackAndLeavesCheckpoint() async throws {
        let db = try store(); try await save(record(), store: db)
        do { try await save(record(offset: 900), store: db); XCTFail("Overlap must fail") } catch {}
        let checkpoint = try await db.checkpoint(); XCTAssertEqual(checkpoint, start.addingTimeInterval(1800))
        let rows = try await db.records(from: start, to: start.addingTimeInterval(4000)); XCTAssertEqual(rows.count, 1)
    }
    func testAdjacentWindowsAdvanceCheckpointWithoutDuplicateTime() async throws {
        let db = try store(); try await save(record(), store: db); try await save(record(offset: 1800), store: db)
        let stats = try await ActivityAnalytics().statistics(store: db, from: start, to: start.addingTimeInterval(3600))
        XCTAssertEqual(stats.tracked, 3600); XCTAssertEqual(stats.focusBlocks.count, 1)
        let checkpoint = try await db.checkpoint(); XCTAssertEqual(checkpoint, start.addingTimeInterval(3600))
    }
    func testDisjointHistoricalWindowCannotMoveCheckpointBackwards() async throws {
        let db = try store(); try await save(record(), store: db); try await save(record(offset: -3600), store: db)
        let checkpoint = try await db.checkpoint(); XCTAssertEqual(checkpoint, start.addingTimeInterval(1800))
    }
    func testTwoConnectionsCannotWriteOverlappingIntervals() async throws {
        let first = try store(), second = try store()
        try await save(record(), store: first)
        do { try await save(record(offset: 600), store: second); XCTFail("Second process must also reject overlap") } catch {}
        let rows = try await second.records(from: start, to: start.addingTimeInterval(3600)); XCTAssertEqual(rows.count, 1)
    }
    func testMultiMonitorEvidenceDoesNotMultiplyTime() async throws {
        let db = try store(); var item = record(); item.evidenceIDs = ["e1", "e2"]; item.backgroundContext = "Music on second display"
        try await db.persist(start: item.start, end: item.end, records: [item], evidence: [evidence(), evidence(display: "Built-in", id: "e2")])
        let totals = try await db.totals(from: item.start, to: item.end, dimension: "intent")
        XCTAssertEqual(totals["BUILD"], 1800); XCTAssertNil(totals["CONSUME"])
    }
    func testOverlappingPrimaryActivitiesRejectedBeforePersistence() async throws {
        let db = try store(); let stop = start.addingTimeInterval(3600)
        var first = record(); var second = record(offset: 900)
        first.windowID = intervalID(start, stop); second.windowID = first.windowID
        do { try await db.persist(start: start, end: stop, records: [first, second], evidence: [evidence()]); XCTFail("Two primary states cannot overlap") } catch {}
        let checkpoint = try await db.checkpoint(); XCTAssertNil(checkpoint)
    }
    func testCategoryAndIntentValidation() throws {
        XCTAssertThrowsError(try decode(json(category: "productive")))
        XCTAssertThrowsError(try decode(json(intent: "WASTED")))
        XCTAssertEqual(try decode(json(category: "technical_learning", intent: "LEARN")).first?.intent, .learn)
    }
    func testMalformedAndOutOfRangeJSONRejected() throws {
        XCTAssertThrowsError(try decode("Please clarify")); XCTAssertThrowsError(try decode(json(confidence: "1.2")))
        XCTAssertThrowsError(try decode(json(offset: -1))); XCTAssertThrowsError(try decode(json(end: 1801)))
    }
    func testUnknownEvidenceIDRejected() throws { XCTAssertThrowsError(try decode(json(evidenceIDs: "[\"invented\"]"))) }
    func testProjectAliasesRequireUniqueEvidenceMatch() throws {
        let projects = ProjectConfiguration(projects: [Project(name: "Example", aliases: ["ExampleProject"])])
        XCTAssertEqual(try decode(json(), projects: projects).first?.projectID, projects.projects.first?.id)
        XCTAssertNil(try decode(json()).first?.projectID) // Model's invented project is ignored.
        XCTAssertNil(projects.infer(from: "OtherExampleProject"))
        let ambiguous = ProjectConfiguration(projects: [Project(name: "One", aliases: ["ExampleProject"]), Project(name: "Two", aliases: ["Xcode"])])
        XCTAssertNil(try decode(json(), projects: ambiguous).first?.projectID)
    }
    func testGapsBecomeUnclearRatherThanInventedWork() throws {
        let records = try decode(json(offset: 300, end: 900))
        XCTAssertEqual(records.count, 3); XCTAssertEqual(records.map(\.duration).reduce(0, +), 1800)
        XCTAssertEqual(records.first?.category, .unclear); XCTAssertEqual(records.last?.intent, .unknown)
    }
    func testOutcomesDecisionsProblemsHaveEvidenceAndConfidence() async throws {
        let facts = """
        [{"kind":"outcome","text":"27 tests passed","evidenceIDs":["e1"],"confidence":0.9,"status":null,"provenance":"INFERRED"},
        {"kind":"decision","text":"Selected SQLite","evidenceIDs":["e1"],"confidence":0.7,"status":null,"provenance":"INFERRED"},
        {"kind":"problem","text":"Permission error","evidenceIDs":["e1"],"confidence":0.6,"status":"OPEN","provenance":"INFERRED"}]
        """
        let records = try decode(json(facts: facts)); let db = try store()
        try await db.persist(start: start, end: start.addingTimeInterval(1800), records: records, evidence: [evidence()])
        let found = try await db.search(ActivitySearch(from: start, to: start.addingTimeInterval(3600), factKind: .decision))
        XCTAssertEqual(found.first?.facts.count, 3); XCTAssertEqual(found.first?.facts.last?.status, .open)
    }
    func testModelCannotDeclareUserConfirmation() throws {
        let fact = #"[{"kind":"decision","text":"Selected SQLite","evidenceIDs":["e1"],"confidence":0.8,"provenance":"USER_CONFIRMED"}]"#
        XCTAssertThrowsError(try decode(json(facts: fact)))
    }
    func testCorrectionOverridesInferenceAndSurvivesReplay() async throws {
        let db = try store(); let item = record(category: .entertainment, intent: .consume)
        try await save(item, store: db)
        try await db.correct(id: item.id, correction: ActivityCorrection(title: "Swift animation tutorial", category: .technical_learning, intent: .learn))
        try await save(item, store: db)
        let rows = try await db.records(from: start, to: start.addingTimeInterval(3600))
        XCTAssertEqual(rows.first?.intent, .learn); XCTAssertEqual(rows.first?.provenance, .userConfirmed)
        let results = try await db.search(ActivitySearch(from: start, to: start.addingTimeInterval(3600), text: "animation")); XCTAssertEqual(results.count, 1)
    }
    func testDailyStatisticsClipIntervalsAtRangeBoundary() async throws {
        let db = try store(); try await save(record(), store: db)
        let stats = try await ActivityAnalytics().statistics(store: db, from: start.addingTimeInterval(600), to: start.addingTimeInterval(1200))
        XCTAssertEqual(stats.tracked, 600); XCTAssertEqual(stats.creation, 600)
    }
    func testUnclearAndEmptyIntervalsAreDistinct() async throws {
        let db = try store()
        try await save(record(category: .unclear, intent: .unknown), store: db)
        try await db.persist(start: start.addingTimeInterval(1800), end: start.addingTimeInterval(3600), records: [], evidence: [])
        let stats = try await ActivityAnalytics().statistics(store: db, from: start, to: start.addingTimeInterval(3600))
        XCTAssertEqual(stats.tracked, 1800); XCTAssertEqual(stats.unclear, 1800); XCTAssertEqual(stats.active, 0)
    }
    func testFocusAndMeaningfulSwitchCalculation() async throws {
        let db = try store()
        try await save(record(duration: 1200), store: db)
        try await save(record(offset: 1200, duration: 1200), store: db)
        try await save(record(offset: 2400, duration: 1800, category: .technical_research, intent: .research, title: "Research API"), store: db)
        let stats = try await ActivityAnalytics().statistics(store: db, from: start, to: start.addingTimeInterval(5000))
        XCTAssertEqual(stats.contextSwitches, 1); XCTAssertEqual(stats.focusBlocks.count, 2)
        XCTAssertEqual(stats.averageFocus, 2100); XCTAssertEqual(stats.medianFocus, 2100)
        let highThreshold = try await ActivityAnalytics(focusThreshold: 3000).statistics(store: db, from: start, to: start.addingTimeInterval(5000))
        XCTAssertEqual(highThreshold.focusBlocks.count, 0)
    }
    func testBriefWindowChangeDoesNotCountAsMeaningfulSwitch() async throws {
        let db = try store(); try await save(record(), store: db)
        try await save(record(offset: 1800, duration: 30, category: .file_management, intent: .administer, title: "Finder"), store: db)
        try await save(record(offset: 1830), store: db)
        let stats = try await ActivityAnalytics().statistics(store: db, from: start, to: start.addingTimeInterval(4000))
        XCTAssertEqual(stats.contextSwitches, 0)
    }
    func testCreationConsumptionAndResearchStaySeparate() async throws {
        let db = try store()
        try await save(record(), store: db)
        try await save(record(offset: 1800, category: .entertainment, intent: .consume), store: db)
        try await save(record(offset: 3600, category: .technical_learning, intent: .learn), store: db)
        try await save(record(offset: 5400, category: .task_planning, intent: .plan), store: db)
        let stats = try await ActivityAnalytics().statistics(store: db, from: start, to: start.addingTimeInterval(7200))
        XCTAssertEqual(stats.creation, 1800); XCTAssertEqual(stats.consumption, 1800); XCTAssertEqual(stats.researchLearning, 1800)
    }
    func testWeeklyAndMonthlyAggregatesUseOriginalFacts() async throws {
        let db = try store(); let item = record(); try await save(item, store: db)
        for period in [ReportPeriod.week, .month] {
            let range = try period.range(containing: start)
            let stats = try await ActivityAnalytics().statistics(store: db, from: range.start, to: range.end)
            XCTAssertEqual(stats.tracked, 1800)
            let report = try await ActivityReport(outputDirectory: root).render(store: db, period: period, date: start)
            XCTAssertTrue(report.contains("Implement feature")); XCTAssertTrue(report.contains("Change from previous"))
            XCTAssertTrue(report.contains("No previous-period history"))
        }
    }
    func testPreviousPeriodComparisonUsesCalendarWeeks() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let week = try ReportPeriod.week.range(containing: start, calendar: calendar)
        let previous = try ReportPeriod.week.previous(week, calendar: calendar)
        XCTAssertEqual(previous.end, week.start); XCTAssertEqual(previous.duration, 7 * 86400)
    }
    func testReportRegenerationAndLegacyBackup() async throws {
        let db = try store(); try await save(record(), store: db)
        let report = ActivityReport(outputDirectory: root)
        let url = root.appendingPathComponent(WorklogWriter.dayKey(start) + ".md")
        try "Legacy history keep me".write(to: url, atomically: true, encoding: .utf8)
        try await report.write(store: db, period: .today, date: start)
        let first = try Data(contentsOf: url)
        try await report.write(store: db, period: .today, date: start)
        XCTAssertEqual(first, try Data(contentsOf: url))
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("legacy-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try String(contentsOf: backups[0]), "Legacy history keep me")
    }
    func testSearchFiltersDateCategoryIntentAndEntity() async throws {
        let db = try store(); var item = record(); item.entities = [ActivityEntity(kind: .technology, name: "Swift")]; try await save(item, store: db)
        let found = try await db.search(ActivitySearch(from: start, to: item.end, text: "feature", category: .coding, intent: .build, entity: "Swift"))
        XCTAssertEqual(found.count, 1)
        let excluded = try await db.search(ActivitySearch(from: item.end, to: item.end.addingTimeInterval(60))); XCTAssertTrue(excluded.isEmpty)
        let noCategory = try await db.search(ActivitySearch(from: start, to: item.end, category: .entertainment)); XCTAssertTrue(noCategory.isEmpty)
    }
    func testSearchTreatsSQLAndFTSSyntaxAsLiteralText() async throws {
        let db = try store(); try await save(record(), store: db)
        let rows = try await db.search(ActivitySearch(from: start, to: start.addingTimeInterval(3600), text: "\" OR *; DROP TABLE activities;"))
        XCTAssertTrue(rows.isEmpty)
        let all = try await db.records(from: start, to: start.addingTimeInterval(3600)); XCTAssertEqual(all.count, 1)
    }
    func testProjectFilterAndIndependentProjectConfidence() async throws {
        let db = try store(); let projects = ProjectConfiguration(projects: [Project(name: "Example", aliases: ["ExampleProject"])])
        let records = try decode(json(), projects: projects)
        try await db.persist(start: start, end: start.addingTimeInterval(1800), records: records, evidence: [evidence()], projects: projects)
        let rows = try await db.search(ActivitySearch(from: start, to: start.addingTimeInterval(3600), project: "Example"))
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.projectConfidence, 0.75)
        let registered = try await db.registeredProjects(); XCTAssertEqual(registered, projects.projects)
    }
    func testSecretsRedactedAtPersistenceBoundary() async throws {
        let db = try store(); var item = record(); item.title = "API_KEY=super-secret-value"; item.summary = item.title
        var proof = evidence(); proof.excerpt = item.title
        try await db.persist(start: item.start, end: item.end, records: [item], evidence: [proof])
        let rows = try await db.records(from: start, to: item.end)
        XCTAssertFalse(rows.first?.title.contains("super-secret-value") ?? true)
        let leaked = try await db.search(ActivitySearch(from: start, to: item.end, text: "super-secret-value")); XCTAssertTrue(leaked.isEmpty)
    }
    func testPromptBudgetAndSecretProtection() {
        let rows = (0..<100).map { ActivityEvidence(id: "e\($0)", timestamp: start, excerpt: "API_KEY=super-secret-value " + String(repeating: "noise ", count: 1000)) }
        let prompt = ActivityPrompts.reconstruction(evidence: rows, start: start, end: start.addingTimeInterval(1800), projects: ProjectConfiguration(), maxContextCharacters: 4000)
        XCTAssertLessThan(prompt.count, 9000); XCTAssertFalse(prompt.contains("super-secret-value"))
        XCTAssertTrue(prompt.contains("Both displays")); XCTAssertTrue(prompt.contains("untrusted DATA"))
    }
    func testLowConfidenceAndFallbackPreserveUncertainty() throws {
        let rows = try decode(json(confidence: "0.1")); XCTAssertEqual(rows.first?.confidence, 0.1)
        let fallback = ActivityReconstruction().fallback(start: start, end: start.addingTimeInterval(1800), evidenceIDs: ["e1"])
        XCTAssertEqual(fallback.intent, .unknown); XCTAssertEqual(fallback.confidence, 0); XCTAssertEqual(fallback.evidenceIDs, ["e1"])
    }
    func testUnknownEvidenceRollsBackWholeTransaction() async throws {
        let db = try store(); var item = record(); item.evidenceIDs = ["not-real"]
        do { try await save(item, store: db); XCTFail("Missing evidence must fail") } catch {}
        let checkpoint = try await db.checkpoint(); XCTAssertNil(checkpoint)
        let contains = try await db.containsWindow(start: item.start, end: item.end); XCTAssertFalse(contains)
    }
    func testLegacyImportClipsOverlapsAndDoesNotModifyOriginals() async throws {
        let directory = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("2026-09-28.md")
        let text = """
        # Worklog

        ## 09:59–10:29
        Could you please clarify?

        ## 09:44–11:14
        ### Activity
        - Reviewed example documentation.

        ## 09:48–11:18
        ### Activity
        - Reviewed example search results.

        ## 11:04–11:19
        ### Activity
        - Edited example notes.
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        let db = try store()
        let first = try await LegacyMarkdownImporter().importDirectory(directory, into: db)
        XCTAssertEqual(first.importedIntervals, 3); XCTAssertEqual(first.importedSeconds, 95 * 60); XCTAssertEqual(first.skippedEntries, 1)
        let second = try await LegacyMarkdownImporter().importDirectory(directory, into: db)
        XCTAssertEqual(second.importedIntervals, 0)
        XCTAssertEqual(try String(contentsOf: url), text)
        let records = try await db.search(ActivitySearch(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)))
        XCTAssertEqual(records.count, 3); XCTAssertTrue(records.allSatisfy { $0.source == .legacyMarkdown && $0.confidence == 0.35 && $0.evidenceIDs.isEmpty })
    }
    func testFutureExplicitWindowIsSkippedAndCheckpointReconnects() async throws {
        let db = try store(); try await save(record(), store: db)
        try await save(record(offset: 3600), store: db)
        let gaps = try await db.unprocessedRanges(from: start.addingTimeInterval(1800), to: start.addingTimeInterval(5400))
        XCTAssertEqual(gaps.count, 1); XCTAssertEqual(gaps.first?.duration, 1800)
        try await save(record(offset: 1800), store: db)
        let checkpoint = try await db.checkpoint(); XCTAssertEqual(checkpoint, start.addingTimeInterval(5400))
    }

    func testReprocessReplacesUnconfirmedRecordsWithoutDuplicatingTime() async throws {
        let db = try store(); let item = record(); try await save(item, store: db)
        var updated = item; updated.title = "Corrected inference"; updated.intent = .fix
        let changed = try await db.persist(start: item.start, end: item.end, records: [updated], evidence: [evidence()], reprocess: true)
        XCTAssertTrue(changed)
        let rows = try await db.records(from: start, to: item.end)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.title, "Corrected inference")
        let totals = try await db.totals(from: start, to: item.end, dimension: "intent"); XCTAssertEqual(totals["FIX"], 1800); XCTAssertNil(totals["BUILD"])
    }
    func testReprocessRefusesToEraseUserCorrections() async throws {
        let db = try store(); let item = record(); try await save(item, store: db)
        try await db.correct(id: item.id, correction: ActivityCorrection(title: "My correction"))
        do { try await db.persist(start: item.start, end: item.end, records: [item], evidence: [evidence()], reprocess: true); XCTFail("Corrections must survive") } catch {}
        let rows = try await db.records(from: start, to: item.end); XCTAssertEqual(rows.first?.title, "My correction")
    }

    func testLowConfidenceEvidenceDoesNotAssignProject() throws {
        let projects = ProjectConfiguration(projects: [Project(name: "Example", aliases: ["ExampleProject"])])
        XCTAssertNil(try decode(json(confidence: "0.1"), projects: projects).first?.projectID)
        var proof = evidence(); proof.confidence = 0.1
        let rows = try ActivityReconstruction().decode(json(), start: start, end: start.addingTimeInterval(1800), evidence: [proof], projects: projects)
        XCTAssertNil(rows.first?.projectID)
    }
    func testDatabaseFileIsPrivateToUser() async throws {
        _ = try store()
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("activity.sqlite").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testReportRangeRejectsYearLongMemoryLoadButSQLTotalsRemainAvailable() async throws {
        let db = try store(); try await save(record(), store: db)
        let end = start.addingTimeInterval(365 * 86400)
        do { _ = try await db.records(from: start, to: end); XCTFail("Use bounded period reports") } catch {}
        let totals = try await db.totals(from: start, to: end, dimension: "intent")
        XCTAssertEqual(totals["BUILD"], 1800)
    }

    func testFactTimestampUsesEvidenceAndDoesNotRepeatAcrossDailyReports() async throws {
        let db = try store()
        let firstDay = Calendar.current.startOfDay(for: start)
        let midnight = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: firstDay))
        let from = midnight.addingTimeInterval(-600), to = midnight.addingTimeInterval(1200)
        var proof = evidence(); proof.timestamp = midnight.addingTimeInterval(300)
        var item = ActivityReconstruction().fallback(start: from, end: to, evidenceIDs: [proof.id])
        item.facts = [ActivityFact(kind: .outcome, text: "Tests passed after midnight", evidenceIDs: [proof.id], confidence: 0.8)]
        try await db.persist(start: from, end: to, records: [item], evidence: [proof])
        let rows = try await db.records(from: from, to: to); XCTAssertEqual(rows.first?.facts.first?.timestamp, proof.timestamp)
        let report = ActivityReport(outputDirectory: root)
        let yesterday = try await report.render(store: db, period: .today, date: from)
        let today = try await report.render(store: db, period: .today, date: proof.timestamp)
        XCTAssertFalse(yesterday.contains("Tests passed after midnight")); XCTAssertTrue(today.contains("Tests passed after midnight"))
    }

    func testOwnedStoreRefusesJustNowDirectoryBeforeWriting() throws {
        let url = WorklogConfiguration.defaultJustNowDirectory.appendingPathComponent("test-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(try ActivityStore(url: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

}

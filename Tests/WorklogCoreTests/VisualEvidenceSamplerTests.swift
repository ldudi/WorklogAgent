import XCTest
@testable import WorklogCore

final class VisualEvidenceSamplerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)
    private func sample(_ texts: [String], displays: [String] = [], hashes: [Data] = [],
                        settings: ScreenshotSelectionSettings = .init(), hours: Double = 1.5,
                        enabled: Bool = true) -> VisualSelection {
        let rows = texts.enumerated().map { index, text -> OCRObservation in
            let date = start.addingTimeInterval(Double(index * 60))
            return OCRObservation(id: "span\(index)", frameID: "frame\(index)", startedAt: date,
                observedThrough: date.addingTimeInterval(59), observationCount: 1,
                displayName: displays.isEmpty ? "External" : displays[index], text: text)
        }
        let images = rows.enumerated().map { index, row in
            ScreenshotEvidence(id: row.frameID, startedAt: row.startedAt, displayName: row.displayName ?? "External",
                url: URL(fileURLWithPath: "/tmp/\(row.frameID).png"),
                perceptualHash: hashes.isEmpty ? Data() : hashes[index])
        }
        return VisualEvidenceSampler().select(images: images, observations: rows, start: start,
            end: start.addingTimeInterval(hours * 3600), settings: settings, visionEnabled: enabled)
    }
    private var distinct: [String] {
        ["Editor implementing orchard apples fruit sorting", "Terminal compiling banana parser library process",
         "Browser researching orange citrus orchard cultivation", "Chat discussing mango database connection pooling",
         "Files organizing grape invoices payroll statement", "Debugger tracing melon memory allocation registers",
         "Document writing cherry customer agreement clauses", "Browser comparing peach satellite launch trajectories",
         "Console inspecting plum network packet latency", "Editor editing pear typography layout constraints",
         "Research reading coconut telescope optics diffraction", "Spreadsheet analyzing avocado revenue quarterly forecasts",
         "Diagram drawing papaya distributed queue architecture", "Viewer showing guava photograph landscape mountains"]
    }
    func testStaticActivityUsesOneEvenWithPreferredMinimum() {
        let result = sample(Array(repeating: distinct[0], count: 90), settings: .init(minimum: 4))
        XCTAssertEqual(result.selected.count, 1)
        XCTAssertEqual(result.metadata.distinctClusterCount, 1)
        XCTAssertEqual(result.metadata.rejectedNearDuplicates, 89)
    }
    func testManyStatesIncreaseSelectionAndComplexityBudget() {
        let quiet = sample([distinct[0]])
        let mixed = sample(Array(distinct.prefix(8)))
        XCTAssertGreaterThan(mixed.selected.count, quiet.selected.count)
        XCTAssertGreaterThan(mixed.metadata.dynamicBudget, quiet.metadata.dynamicBudget)
        XCTAssertEqual(mixed.metadata.dynamicBudget, 6)
    }
    func testHardMaximumAndSafetyCeiling() {
        let result = sample(distinct, settings: .init(maximum: 3))
        XCTAssertEqual(result.selected.count, 3)
        XCTAssertEqual(ScreenshotSelectionSettings(minimum: 99, maximum: 999).maximum, 12)
        XCTAssertEqual(ScreenshotSelectionSettings(minimum: 99, maximum: 999).minimum, 12)
        XCTAssertEqual(sample(distinct, settings: .init(dynamic: false, maximum: 999)).selected.count, 12)
    }
    func testNearIdenticalTextCollapsesDespiteChangingHashes() {
        let texts = [distinct[0], distinct[0] + " 01", distinct[0]]
        let result = sample(texts, hashes: [Data(repeating: 0, count: 8), Data(repeating: 255, count: 8), Data(repeating: 1, count: 8)])
        XCTAssertEqual(result.selected.count, 1)
    }
    func testContextSwitchSurvivesEvenWithSameHash() {
        let result = sample(Array(distinct.prefix(3)), hashes: Array(repeating: Data(repeating: 0, count: 8), count: 3))
        XCTAssertEqual(result.selected.count, 3)
        XCTAssertTrue(result.selected.contains { $0.text.contains("Terminal") })
    }
    func testPartialOCRPreservesComplementaryVisualContext() {
        let result = sample(["Editor • implementing • source • library • feature", "Browser • researching • document • architecture • discussion"], displays: ["External", "Built-in"])
        XCTAssertEqual(result.selected.count, 2)
        XCTAssertEqual(Set(result.selected.map { $0.image.displayName }).count, 2)
        XCTAssertTrue(result.selected.allSatisfy { $0.reasons.contains("partial OCR; visual context") })
    }
    func testApplicationMenuChangeSurvivesSameContentAndHash() {
        let result = sample(["Editor File Edit View Window Help\n" + distinct[0], "Browser File Edit View Window Help\n" + distinct[0]],
            hashes: Array(repeating: Data(repeating: 0, count: 8), count: 2))
        XCTAssertEqual(result.selected.count, 2)
    }
    func testBareWebDomainsPreserveContextWithoutTreatingSourceExtensionsAsDomains() {
        let body = Array(repeating: "Browser reading documentation researching system architecture", count: 20).joined(separator: " ")
        let sites = sample([body + "\nexample.com", body + "\nresearch.org"],
            hashes: Array(repeating: Data(repeating: 0, count: 8), count: 2))
        XCTAssertEqual(sites.selected.count, 2)
        let files = sample([body + "\nfirst.swift", body + "\nsecond.swift"],
            hashes: Array(repeating: Data(repeating: 0, count: 8), count: 2))
        XCTAssertEqual(files.selected.count, 1)
    }
    func testBothMeaningfulDisplaysSurvive() {
        let result = sample([distinct[0], distinct[3]], displays: ["External", "Built-in"])
        XCTAssertEqual(Set(result.selected.map { $0.image.displayName }), ["External", "Built-in"])
    }
    func testNoisySecondaryDisplayIsNotForced() {
        let result = sample([distinct[0], "••••••"], displays: ["External", "Built-in"],
            hashes: Array(repeating: Data(repeating: 0, count: 8), count: 2))
        XCTAssertEqual(result.selected.count, 1)
        XCTAssertEqual(result.selected.first?.image.displayName, "External")
        XCTAssertEqual(result.metadata.rejectedLowValue, 1)
    }
    func testErrorBoostAndRetentionUnderPressure() {
        let result = sample(distinct + ["Terminal compiler error failed fatal exception"], settings: .init(maximum: 2))
        let error = result.selected.first { $0.text.contains("fatal") }
        XCTAssertNotNil(error)
        XCTAssertGreaterThan(error?.score ?? 0, 0.8)
        XCTAssertTrue(error?.reasons.contains("possible error/failure") ?? false)
    }
    func testResultBoostAndRetentionUnderPressure() {
        let result = sample(distinct + ["Terminal all tests passed build succeeded"], settings: .init(maximum: 2))
        XCTAssertTrue(result.selected.contains { $0.reasons.contains("possible result/success") })
        XCTAssertEqual(result.metadata.highValueOutcomeCount, 1)
    }
    func testBeginningTransitionAndOutcome() {
        let result = sample([distinct[0], "Terminal running test suite command execution", "Terminal tests passed build succeeded"])
        XCTAssertEqual(result.selected.map { $0.image.id }, ["frame0", "frame1", "frame2"])
    }
    func testNoUsefulEvidenceCanSelectZeroOrOne() {
        XCTAssertEqual(sample(["•••", ""]).selected.count, 0)
        XCTAssertEqual(sample([""], hashes: [Data(repeating: 0, count: 8)]).selected.count, 1)
        XCTAssertEqual(sample(distinct, settings: .init(maximum: 0)).selected.count, 0)
        XCTAssertEqual(sample(distinct, enabled: false).selected.count, 0)
    }
    func testDurationAloneDoesNotInflateStaticSelection() {
        XCTAssertEqual(sample(Array(repeating: distinct[0], count: 20), hours: 24).selected.count, 1)
        let short = sample(distinct, hours: 1).metadata.dynamicBudget
        let long = sample(distinct, hours: 24).metadata.dynamicBudget
        XCTAssertEqual(long - short, 1)
    }
    func testConsumptionRepetitionDoesNotFillBudget() {
        let playback = "Music player pause play playlist volume ambient listening"
        let result = sample([distinct[0]] + Array(repeating: playback, count: 70),
            displays: ["External"] + Array(repeating: "Built-in", count: 70))
        XCTAssertEqual(result.selected.count, 2)
        XCTAssertEqual(result.selected.filter { $0.image.displayName == "Built-in" }.count, 1)
        XCTAssertGreaterThan(result.selected[0].score, result.selected[1].score)
    }
    func testOutcomeChangeSurvivesSimilarOCRAndHash() {
        let body = Array(repeating: "Editor source library function package application value code context", count: 12).joined(separator: " ")
        let texts = [body + "\nTerminal tests running", body + "\nTerminal tests passed", body + "\nTerminal error failed"]
        let result = sample(texts, hashes: Array(repeating: Data(repeating: 0, count: 8), count: 3))
        XCTAssertEqual(result.selected.count, 3)
        XCTAssertEqual(result.metadata.highValueOutcomeCount, 2)
    }
    func testCrossDisplayDuplicatesFreeSlotsForOtherStates() {
        let result = sample([distinct[0], distinct[0], distinct[1]], displays: ["External", "Built-in", "External"])
        XCTAssertEqual(result.selected.count, 2)
        XCTAssertTrue(result.selected.contains { $0.text.contains("Terminal") })
    }
    func testCrossDisplayDuplicateRetainsHigherImportanceBeforeDiversity() {
        let result = sample([distinct[0], distinct[1], distinct[1]],
            displays: ["External", "Built-in", "External"], settings: .init(maximum: 2))
        XCTAssertEqual(result.selected.count, 2)
        // The single useful frame on Built-in carries both endpoint boosts and has
        // higher base importance; External's final duplicate must not displace it.
        XCTAssertTrue(result.selected.contains { $0.image.id == "frame1" })
        XCTAssertFalse(result.selected.contains { $0.image.id == "frame2" })
    }
    func testChangingResultCountIsNotDiscardedWithNumericClockNoise() {
        let result = sample(["Terminal test suite 73 tests passed", "Terminal test suite 74 tests passed"],
            hashes: Array(repeating: Data(repeating: 0, count: 8), count: 2))
        XCTAssertEqual(result.selected.count, 2)
        XCTAssertEqual(result.metadata.highValueOutcomeCount, 2)
    }
    func testDefaultSettingsMigrateWithoutOverwritingVisionPreference() throws {
        let name = "VisualSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "useScreenshots")
        let migrated = ScreenshotSelectionSettings(defaults: defaults)
        XCTAssertTrue(migrated.dynamic); XCTAssertEqual(migrated.minimum, 1); XCTAssertEqual(migrated.maximum, 12)
        migrated.save(to: defaults)
        XCTAssertFalse(defaults.bool(forKey: "useScreenshots"))
        defaults.set(99, forKey: "minimumScreenshots"); defaults.set(-1, forKey: "maximumScreenshots")
        XCTAssertEqual(ScreenshotSelectionSettings(defaults: defaults).minimum, 0)
        XCTAssertEqual(ScreenshotSelectionSettings(defaults: defaults).maximum, 0)
    }
    func testPolicyMetadataContainsNoOCR() throws {
        let result = sample([distinct[0] + " secret private phrase"])
        let encoded = String(decoding: try JSONEncoder().encode(result.metadata), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private phrase")); XCTAssertFalse(result.metadata.diagnostics.contains("orchard"))
        XCTAssertEqual(result.metadata.policyVersion, 2)
        XCTAssertEqual(result.metadata.selected.first?.frameID, "frame0")
    }
    func testDeterminismForReorderedInput() {
        let images = (0..<5).map { ScreenshotEvidence(id: "f\($0)", startedAt: start.addingTimeInterval(Double($0 * 60)),
            displayName: "External", url: URL(fileURLWithPath: "/tmp/f\($0).png"), perceptualHash: Data()) }
        let rows = images.enumerated().map { OCRObservation(id: "s\($0.offset)", frameID: $0.element.id,
            startedAt: $0.element.startedAt, observedThrough: $0.element.startedAt.addingTimeInterval(30),
            observationCount: 1, displayName: "External", text: distinct[$0.offset]) }
        let sampler = VisualEvidenceSampler()
        let a = sampler.select(images: images, observations: rows, start: start, end: start.addingTimeInterval(1000))
        let b = sampler.select(images: images.reversed(), observations: rows.reversed(), start: start, end: start.addingTimeInterval(1000))
        XCTAssertEqual(a.metadata, b.metadata)
    }
    func testPersistMetadataReplayAndReprocessingAreAtomic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ActivityStore(url: root.appendingPathComponent("owned.sqlite"))
        let end = start.addingTimeInterval(600)
        let first = sample([distinct[0]]).metadata
        let second = sample(Array(distinct.prefix(3))).metadata
        let inserted = try await store.persist(start: start, end: end, records: [], evidence: [], visualSelection: first)
        XCTAssertTrue(inserted)
        let replay = try await store.persist(start: start, end: end, records: [], evidence: [], visualSelection: second)
        XCTAssertFalse(replay)
        let original = try await store.visualSelection(start: start, end: end)
        XCTAssertEqual(original, first)
        let replaced = try await store.persist(start: start, end: end, records: [], evidence: [], reprocess: true, visualSelection: second)
        XCTAssertTrue(replaced)
        let changed = try await store.visualSelection(start: start, end: end)
        XCTAssertEqual(changed, second)
        // Invalid activity must roll back the metadata replacement and retain the entire prior window.
        let invalid = ActivityRecord(id: "invalid", windowID: "wrong", start: start, end: end, title: "Invalid", summary: "", category: .coding, intent: .build, projectConfidence: 0, confidence: 0.5, classificationConfidence: 0.5, source: .justNow, provenance: .inferred, backgroundContext: "", entities: [], evidenceIDs: [], facts: [], createdAt: start, updatedAt: start)
        do {
            _ = try await store.persist(start: start, end: end, records: [invalid], evidence: [], reprocess: true, visualSelection: first)
            XCTFail("Invalid records must fail")
        } catch {}
        let afterFailure = try await store.visualSelection(start: start, end: end)
        XCTAssertEqual(afterFailure, second)
    }
    func testSettingsMutationCannotBypassSafetyCap() {
        var settings = ScreenshotSelectionSettings()
        settings.maximum = 1000; settings.minimum = 999
        XCTAssertLessThanOrEqual(sample(distinct, settings: settings).selected.count, 12)
    }
    func testAllOutcomeTermsUseWordBoundaries() {
        for word in ["error", "failed", "failure", "exception", "fatal", "warning", "crash", "passed", "success", "succeeded", "deployed", "completed", "merged", "submitted"] {
            XCTAssertGreaterThan(OutcomeSignals.boost("Terminal command \(word)").0, 0, word)
        }
        XCTAssertEqual(OutcomeSignals.boost("terror successful password").0, 0)
    }
}

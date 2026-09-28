import Foundation
import CryptoKit

public enum ActivityCategory: String, Codable, CaseIterable, Sendable {
    case coding, product_building, writing, design, content_creation
    case technical_research, product_research, market_research, debugging_research, documentation
    case tutorial, course, technical_learning, reading
    case communication, email, messaging, meetings, professional_network, personal
    case deployment, git, file_management, environment_setup, testing, administration
    case roadmap, task_planning, ideation, reviewing_work
    case entertainment, social_media, news, unclear
}
public enum ActivityIntent: String, Codable, CaseIterable, Sendable {
    case build = "BUILD", learn = "LEARN", research = "RESEARCH", plan = "PLAN", fix = "FIX"
    case communicate = "COMMUNICATE", administer = "ADMINISTER", consume = "CONSUME", unknown = "UNKNOWN"
}
public enum Provenance: String, Codable, Sendable { case observed = "OBSERVED", inferred = "INFERRED", userConfirmed = "USER_CONFIRMED" }
public enum ActivitySource: String, Codable, Sendable { case justNow, fallback, legacyMarkdown }
public enum EntityKind: String, Codable, Sendable { case application, repository, file, website, domain, technology, language, framework, person, document, topic }
public struct ActivityEntity: Codable, Equatable, Sendable {
    public var kind: EntityKind
    public var name: String
    public init(kind: EntityKind, name: String) { self.kind = kind; self.name = name }
}
public struct Project: Codable, Equatable, Sendable {
    public var name: String
    public var aliases: [String]
    public var repository: String?
    public init(name: String, aliases: [String] = [], repository: String? = nil) {
        self.name = name; self.aliases = aliases; self.repository = repository
    }
    public var id: String { stableID(name.lowercased()) }
}
public struct ProjectConfiguration: Codable, Sendable {
    public var projects: [Project]
    public init(projects: [Project] = []) { self.projects = projects }
    public func infer(from text: String) -> Project? {
        let matches = projects.filter { project in
            ([project.name] + project.aliases).contains { alias in
                guard !alias.isEmpty else { return false }
                let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: alias) + "(?![\\p{L}\\p{N}_])"
                return text.range(of: pattern, options: .regularExpression) != nil
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
public struct ActivityEvidence: Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var display: String?
    public var excerpt: String
    public var screenshotReference: String?
    public var type: String
    public var sourceReference: String?
    public var provenance: Provenance
    public var confidence: Double
    public init(id: String, timestamp: Date, display: String? = nil, excerpt: String,
                screenshotReference: String? = nil, type: String = "ocr", confidence: Double = 0.6,
                sourceReference: String? = nil, provenance: Provenance = .observed) {
        self.id = id; self.timestamp = timestamp; self.display = display; self.excerpt = excerpt
        self.screenshotReference = screenshotReference; self.type = type; self.confidence = confidence
        self.sourceReference = sourceReference; self.provenance = provenance
    }
}
public enum FactKind: String, Codable, Sendable { case outcome, problem, decision }
public enum ProblemStatus: String, Codable, Sendable { case open = "OPEN", resolved = "RESOLVED", unknown = "UNKNOWN" }
public struct ActivityFact: Codable, Equatable, Sendable {
    public var kind: FactKind
    public var text: String
    public var evidenceIDs: [String]
    public var confidence: Double
    public var status: ProblemStatus?
    public var timestamp: Date? = nil
    public var provenance: Provenance = .inferred
}
public struct ActivityRecord: Codable, Equatable, Sendable {
    public var id: String
    public var windowID: String
    public var start: Date
    public var end: Date
    public var title: String
    public var summary: String
    public var category: ActivityCategory
    public var intent: ActivityIntent
    public var projectID: String?
    public var projectConfidence: Double
    public var confidence: Double
    public var classificationConfidence: Double
    public var source: ActivitySource
    public var provenance: Provenance
    public var backgroundContext: String
    public var entities: [ActivityEntity]
    public var evidenceIDs: [String]
    public var facts: [ActivityFact]
    public var createdAt: Date
    public var updatedAt: Date
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public enum ActivityValidationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
}

/// Transport offsets are relative to the server-owned interval; the model cannot choose arbitrary dates.
struct ActivityResponse: Decodable { var activities: [ActivityDraft] }
struct ActivityDraft: Decodable {
    var startOffset: Double
    var endOffset: Double
    var title: String
    var summary: String
    var category: ActivityCategory
    var intent: ActivityIntent
    var project: String?
    var confidence: Double
    var classificationConfidence: Double
    var backgroundContext: String
    var entities: [ActivityEntity]
    var evidenceIDs: [String]
    var facts: [ActivityFact]
}
public struct ActivityReconstruction {
    public init() {}
    public func decode(_ json: String, start: Date, end: Date, evidence: [ActivityEvidence],
                       projects: ProjectConfiguration = ProjectConfiguration()) throws -> [ActivityRecord] {
        guard end > start, json.utf8.count <= 100_000 else { throw ActivityValidationError.invalid("Invalid interval or oversized JSON") }
        let decoded = try JSONDecoder().decode(ActivityResponse.self, from: Data(json.utf8))
        guard !decoded.activities.isEmpty, decoded.activities.count <= 48 else { throw ActivityValidationError.invalid("Expected 1–48 primary activities") }
        let window = intervalID(start, end)
        let duration = end.timeIntervalSince(start)
        let evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let redactor = SecretRedactor()
        var cursor: Double = 0
        var records: [ActivityRecord] = []
        for draft in decoded.activities.sorted(by: { $0.startOffset < $1.startOffset }) {
            guard draft.startOffset.isFinite, draft.endOffset.isFinite,
                  draft.startOffset >= cursor, draft.endOffset > draft.startOffset, draft.endOffset <= duration else {
                throw ActivityValidationError.invalid("Block '\(SecretRedactor().redact(draft.title))' has offsets \(draft.startOffset)–\(draft.endOffset); start must be >= previous end \(cursor), end must be > start and <= \(duration). Merge simultaneous displays into one primary timeline.")
            }
            guard validConfidence(draft.confidence), validConfidence(draft.classificationConfidence),
                  !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  draft.title.count <= 240, draft.summary.count <= 2000, draft.backgroundContext.count <= 1000,
                  !draft.evidenceIDs.isEmpty, draft.evidenceIDs.count <= 24,
                  draft.evidenceIDs.allSatisfy({ evidenceByID[$0] != nil }), draft.entities.count <= 32,
                  draft.entities.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 240 }), draft.facts.count <= 24 else {
                throw ActivityValidationError.invalid("Invalid bounds, confidence, fields, or evidence references")
            }
            for fact in draft.facts {
                guard validConfidence(fact.confidence), !fact.text.isEmpty, fact.text.count <= 1000,
                      !fact.evidenceIDs.isEmpty, fact.evidenceIDs.allSatisfy({ draft.evidenceIDs.contains($0) }),
                      (fact.kind == .problem || fact.status == nil), fact.provenance == .inferred else { throw ActivityValidationError.invalid("Unsupported model fact") }
            }
            if draft.startOffset > cursor {
                records.append(fallback(start: start.addingTimeInterval(cursor), end: start.addingTimeInterval(draft.startOffset), windowID: window, evidenceIDs: []))
            }
            let selectedText = draft.evidenceIDs.compactMap { evidenceByID[$0]?.excerpt }.joined(separator: "\n")
            let project = draft.confidence >= 0.5 && draft.evidenceIDs.contains(where: { (evidenceByID[$0]?.confidence ?? 0) >= 0.5 }) ? projects.infer(from: selectedText) : nil
            // Only a uniquely matched configured name/alias may become a canonical project.
            let now = Date()
            records.append(ActivityRecord(id: stableID("\(window):\(draft.startOffset):\(draft.endOffset)"), windowID: window,
                start: start.addingTimeInterval(draft.startOffset), end: start.addingTimeInterval(draft.endOffset),
                title: redactor.redact(draft.title), summary: redactor.redact(draft.summary), category: draft.category, intent: draft.intent,
                projectID: project?.id, projectConfidence: project == nil ? 0 : 0.75,
                confidence: draft.confidence, classificationConfidence: draft.classificationConfidence, source: .justNow,
                provenance: .inferred, backgroundContext: redactor.redact(draft.backgroundContext),
                entities: draft.entities.map { ActivityEntity(kind: $0.kind, name: redactor.redact($0.name)) }, evidenceIDs: draft.evidenceIDs,
                facts: draft.facts.map { fact in var f = fact; f.text = redactor.redact(f.text); return f }, createdAt: now, updatedAt: now))
            cursor = draft.endOffset
        }
        if cursor < duration { records.append(fallback(start: start.addingTimeInterval(cursor), end: end, windowID: window, evidenceIDs: [])) }
        return records
    }
    public func fallback(start: Date, end: Date, windowID: String? = nil, evidenceIDs: [String], reason: String = "Insufficient reliable evidence") -> ActivityRecord {
        let window = windowID ?? intervalID(start, end)
        return ActivityRecord(id: stableID("\(window):fallback:\(start.timeIntervalSince1970):\(end.timeIntervalSince1970)"), windowID: window,
            start: start, end: end, title: "Unclear activity", summary: SecretRedactor().redact(String(reason.prefix(500))), category: .unclear, intent: .unknown,
            projectID: nil, projectConfidence: 0, confidence: 0, classificationConfidence: 0, source: .fallback, provenance: .inferred,
            backgroundContext: "", entities: [], evidenceIDs: evidenceIDs, facts: [], createdAt: Date(), updatedAt: Date())
    }
}
func validConfidence(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
func stableID(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
func intervalID(_ start: Date, _ end: Date) -> String { stableID("\(start.timeIntervalSince1970):\(end.timeIntervalSince1970)") }

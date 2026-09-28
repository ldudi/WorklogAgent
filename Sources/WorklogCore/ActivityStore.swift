import Foundation
import CSQLite

private enum SQLValue { case text(String), number(Double), null }
private final class OwnedDatabase {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw WorklogError.sqlite("Cannot open owned activity database")
        }
        handle = pointer
        sqlite3_busy_timeout(pointer, 5000)
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA journal_mode=WAL")
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[String?]] {
        guard let handle else { throw WorklogError.sqlite("Closed database") }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw WorklogError.sqlite(String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let success: Bool
            switch value {
            case .text(let text): success = bindText(text, to: prepared, index: index)
            case .number(let number): success = sqlite3_bind_double(prepared, index, number) == SQLITE_OK
            case .null: success = sqlite3_bind_null(prepared, index) == SQLITE_OK
            }
            guard success else { throw WorklogError.sqlite(String(cString: sqlite3_errmsg(handle))) }
        }
        var result: [[String?]] = []
        while true {
            let code = sqlite3_step(prepared)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw WorklogError.sqlite(String(cString: sqlite3_errmsg(handle))) }
            result.append((0..<sqlite3_column_count(prepared)).map { sqliteText(prepared, $0) })
        }
    }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try rows(sql, values) }
    func script(_ sql: String) throws {
        guard let handle else { throw WorklogError.sqlite("Closed database") }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw WorklogError.sqlite(String(cString: sqlite3_errmsg(handle))) }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try execute("ROLLBACK"); throw error }
    }
    func backup(to url: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open(url.path, &destination) == SQLITE_OK, let destination else { throw WorklogError.sqlite("Cannot create migration backup") }
        defer { sqlite3_close(destination) }
        guard let handle, let backup = sqlite3_backup_init(destination, "main", handle, "main") else { throw WorklogError.sqlite("Cannot initialize backup") }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw WorklogError.sqlite("Migration backup failed") }
    }
}

public struct ActivitySearch: Sendable {
    public var from: Date
    public var to: Date
    public var text: String?
    public var project: String?
    public var category: ActivityCategory?
    public var intent: ActivityIntent?
    public var entity: String?
    public var factKind: FactKind?
    public var limit: Int
    public init(from: Date = Date(timeIntervalSince1970: 0), to: Date = Date(), text: String? = nil,
                project: String? = nil, category: ActivityCategory? = nil, intent: ActivityIntent? = nil,
                entity: String? = nil, factKind: FactKind? = nil, limit: Int = 100) {
        self.from = from; self.to = to; self.text = text; self.project = project; self.category = category
        self.intent = intent; self.entity = entity; self.factKind = factKind; self.limit = limit
    }
}
public struct ActivityCorrection: Codable, Sendable {
    public var title: String?
    public var category: ActivityCategory?
    public var intent: ActivityIntent?
    public var projectID: String?
    public var clearProject: Bool
    public init(title: String? = nil, category: ActivityCategory? = nil, intent: ActivityIntent? = nil,
                projectID: String? = nil, clearProject: Bool = false) {
        self.title = title; self.category = category; self.intent = intent; self.projectID = projectID; self.clearProject = clearProject
    }
}

/// The actor owns its SQLite connection. BEGIN IMMEDIATE plus database triggers also protects concurrent CLI/app processes.
public actor ActivityStore {
    public static let schemaVersion = 3
    public static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorklogAgent/worklog.sqlite") }
    public let url: URL
    private let db: OwnedDatabase
    public init(url: URL = ActivityStore.defaultURL) throws {
        self.url = url
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let external = WorklogConfiguration.defaultJustNowDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard target != external, !target.hasPrefix(external + "/") else {
            throw ActivityValidationError.invalid("The owned activity database cannot be stored inside JustNow's directory")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try OwnedDatabase(url: url)
        let version = Int(try database.rows("PRAGMA user_version").first?.first.flatMap { $0 } ?? "0") ?? 0
        guard version <= Self.schemaVersion else { throw WorklogError.sqlite("Database is newer than this app; refusing downgrade") }
        if version > 0 && version < Self.schemaVersion {
            let backup = url.appendingPathExtension("v\(version)-\(UUID().uuidString).backup")
            try database.backup(to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try database.transaction {
            // Another app process may have migrated while this connection waited for its write lock.
            let current = Int(try database.rows("PRAGMA user_version").first?.first.flatMap { $0 } ?? "0") ?? 0
            guard current <= Self.schemaVersion else { throw WorklogError.sqlite("Database is newer than this app") }
            if current < 1 { try database.script(Self.migration1) }
            if current < 2 { try database.script(Self.migration2) }
            if current < 3 { try database.script(Self.migration3) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        db = database
    }
    public func version() throws -> Int { Int(try db.rows("PRAGMA user_version").first?.first.flatMap { $0 } ?? "0") ?? 0 }
    public func checkpoint() throws -> Date? {
        guard let value = try db.rows("SELECT value FROM metadata WHERE key='lastProcessedTimestamp'").first?.first.flatMap({ $0 }), let time = Double(value) else { return nil }
        return Date(timeIntervalSince1970: time)
    }
    public func containsWindow(start: Date, end: Date) throws -> Bool {
        !(try db.rows("SELECT id FROM processing_windows WHERE id=?", [.text(intervalID(start, end))])).isEmpty
    }
    public func unprocessedRanges(from: Date, to: Date) throws -> [DateInterval] {
        guard to > from else { return [] }
        let rows = try db.rows("SELECT start,end FROM processing_windows WHERE start < ? AND end > ? ORDER BY start", [.number(to.timeIntervalSince1970), .number(from.timeIntervalSince1970)])
        var cursor = from
        var ranges: [DateInterval] = []
        for row in rows {
            guard let a = row[0].flatMap(Double.init), let b = row[1].flatMap(Double.init) else { throw WorklogError.sqlite("Invalid stored processing window") }
            let start = Date(timeIntervalSince1970: a), end = Date(timeIntervalSince1970: b)
            if start > cursor { ranges.append(DateInterval(start: cursor, end: min(start, to))) }
            cursor = max(cursor, end)
        }
        if cursor < to { ranges.append(DateInterval(start: cursor, end: to)) }
        return ranges
    }
    public func checkAvailable(start: Date, end: Date) throws {
        guard end > start else { throw ActivityValidationError.invalid("End must follow start") }
        let rows = try db.rows("SELECT id FROM processing_windows WHERE start < ? AND end > ? AND id != ? LIMIT 1",
                               [.number(end.timeIntervalSince1970), .number(start.timeIntervalSince1970), .text(intervalID(start, end))])
        guard rows.isEmpty else { throw ActivityValidationError.invalid("Interval overlaps canonical history. Use inspect or an explicit lookback for inspection.") }
    }
    @discardableResult
    public func persist(start: Date, end: Date, records: [ActivityRecord], evidence: [ActivityEvidence],
                        projects: ProjectConfiguration = ProjectConfiguration(), advanceCheckpoint: Bool = true, reprocess: Bool = false) throws -> Bool {
        let window = intervalID(start, end)
        return try db.transaction {
            if try containsWindow(start: start, end: end) {
                if !reprocess { return false }
                let confirmed = try db.rows("SELECT id FROM activities WHERE window_id=? AND provenance='USER_CONFIRMED' LIMIT 1", [.text(window)])
                guard confirmed.isEmpty else { throw ActivityValidationError.invalid("This interval contains user corrections; reprocessing is refused to preserve them") }
                try db.execute("DELETE FROM activity_fts WHERE activity_id IN (SELECT id FROM activities WHERE window_id=?)", [.text(window)])
                try db.execute("DELETE FROM activities WHERE window_id=?", [.text(window)])
                try db.execute("DELETE FROM evidence WHERE window_id=?", [.text(window)])
                try db.execute("DELETE FROM processing_windows WHERE id=?", [.text(window)])
            }
            try checkAvailable(start: start, end: end)
            var cursor = start
            let knownEvidence = Set(evidence.map(\.id))
            for record in records.sorted(by: { $0.start < $1.start }) {
                guard record.windowID == window, record.start >= cursor, record.end <= end, record.end > record.start,
                      validConfidence(record.confidence), validConfidence(record.classificationConfidence), validConfidence(record.projectConfidence),
                      record.evidenceIDs.allSatisfy({ knownEvidence.contains($0) }), record.title.count <= 240 else { throw ActivityValidationError.invalid("Invalid canonical record") }
                for fact in record.facts {
                    guard validConfidence(fact.confidence), !fact.evidenceIDs.isEmpty,
                          fact.evidenceIDs.allSatisfy({ record.evidenceIDs.contains($0) }) else { throw ActivityValidationError.invalid("Invalid fact provenance") }
                }
                cursor = record.end
            }
            try db.execute("INSERT INTO processing_windows(id,start,end,created_at) VALUES(?,?,?,?)", [.text(window), .number(start.timeIntervalSince1970), .number(end.timeIntervalSince1970), .number(Date().timeIntervalSince1970)])
            for project in projects.projects {
                let assigned = records.filter { $0.projectID == project.id }
                let firstSeen = assigned.map(\.start).min().map { SQLValue.number($0.timeIntervalSince1970) } ?? .null
                let lastSeen = assigned.map(\.end).max().map { SQLValue.number($0.timeIntervalSince1970) } ?? .null
                try db.execute("INSERT INTO projects(id,name,aliases,repository,first_seen,last_seen,status) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,aliases=excluded.aliases,repository=excluded.repository,first_seen=CASE WHEN first_seen IS NULL THEN excluded.first_seen WHEN excluded.first_seen IS NULL THEN first_seen ELSE MIN(first_seen,excluded.first_seen) END,last_seen=CASE WHEN last_seen IS NULL THEN excluded.last_seen WHEN excluded.last_seen IS NULL THEN last_seen ELSE MAX(last_seen,excluded.last_seen) END,status=CASE WHEN excluded.last_seen IS NULL THEN status ELSE 'active' END",
                    [.text(project.id), .text(safe(project.name)), .text(try json(project.aliases.map(safe))), project.repository.map { .text(safe($0)) } ?? .null, firstSeen, lastSeen, .text(assigned.isEmpty ? "configured" : "active")])
            }
            for item in evidence {
                guard validConfidence(item.confidence) else { throw ActivityValidationError.invalid("Invalid evidence confidence") }
                try db.execute("INSERT OR IGNORE INTO evidence(id,window_id,timestamp,display,excerpt,screenshot_reference,type,confidence,source_reference,provenance) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    [.text(item.id), .text(window), .number(item.timestamp.timeIntervalSince1970), item.display.map { .text(safe($0)) } ?? .null,
                     .text(String(safe(item.excerpt).prefix(900))), item.screenshotReference.map { .text(safe($0)) } ?? .null, .text(item.type), .number(item.confidence), item.sourceReference.map { .text(safe($0)) } ?? .null, .text(item.provenance.rawValue)])
            }
            for var record in records {
                record.title = safe(record.title); record.summary = safe(record.summary); record.backgroundContext = safe(record.backgroundContext)
                record.entities = record.entities.map { ActivityEntity(kind: $0.kind, name: safe($0.name)) }
                record.facts = record.facts.map { fact in
                    var f = fact; f.text = safe(f.text)
                    let supportedTime = evidence.filter { fact.evidenceIDs.contains($0.id) }.map(\.timestamp).min() ?? record.start
                    f.timestamp = max(record.start, min(record.end, supportedTime))
                    return f
                }
                try insert(record)
            }
            try refreshProjects()
            if advanceCheckpoint {
                let previous = try checkpoint()
                // An explicit historical range must not skip unprocessed time after the checkpoint.
                if previous == nil || start == previous {
                    var contiguousEnd = end.timeIntervalSince1970
                    while let row = try db.rows("SELECT end FROM processing_windows WHERE start=?", [.number(contiguousEnd)]).first,
                          let next = row[0].flatMap(Double.init), next > contiguousEnd { contiguousEnd = next }
                    try db.execute("INSERT INTO metadata(key,value) VALUES('lastProcessedTimestamp',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(String(contiguousEnd))])
                }
            }
            return true
        }
    }
    private func insert(_ record: ActivityRecord) throws {
        try db.execute("INSERT INTO activities(id,window_id,start,end,title,summary,category,intent,project_id,confidence,classification_confidence,project_confidence,source,provenance,payload,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [.text(record.id), .text(record.windowID), .number(record.start.timeIntervalSince1970), .number(record.end.timeIntervalSince1970), .text(record.title), .text(record.summary), .text(record.category.rawValue), .text(record.intent.rawValue), record.projectID.map(SQLValue.text) ?? .null,
             .number(record.confidence), .number(record.classificationConfidence), .number(record.projectConfidence), .text(record.source.rawValue), .text(record.provenance.rawValue), .text(try json(record)), .number(record.createdAt.timeIntervalSince1970), .number(record.updatedAt.timeIntervalSince1970)])
        for id in Set(record.evidenceIDs) { try db.execute("INSERT INTO activity_evidence(activity_id,evidence_id) VALUES(?,?)", [.text(record.id), .text(id)]) }
        for entity in Set(record.entities.map { $0.kind.rawValue + ":" + $0.name }) {
            guard let item = record.entities.first(where: { $0.kind.rawValue + ":" + $0.name == entity }) else { continue }
            let id = stableID(entity.lowercased())
            try db.execute("INSERT OR IGNORE INTO entities(id,kind,name) VALUES(?,?,?)", [.text(id), .text(item.kind.rawValue), .text(item.name)])
            try db.execute("INSERT OR IGNORE INTO activity_entities(activity_id,entity_id) VALUES(?,?)", [.text(record.id), .text(id)])
        }
        for (index, fact) in record.facts.enumerated() {
            try db.execute("INSERT INTO facts(id,activity_id,kind,text,timestamp,project_id,confidence,provenance,status,evidence_ids) VALUES(?,?,?,?,?,?,?,?,?,?)",
                [.text(stableID("\(record.id):\(index)")), .text(record.id), .text(fact.kind.rawValue), .text(fact.text), .number((fact.timestamp ?? record.start).timeIntervalSince1970), record.projectID.map(SQLValue.text) ?? .null, .number(fact.confidence), .text(fact.provenance.rawValue), fact.status.map { .text($0.rawValue) } ?? .null, .text(try json(fact.evidenceIDs))])
        }
        try index(record)
    }
    private func index(_ record: ActivityRecord) throws {
        let body = ([record.title, record.summary, record.backgroundContext] + record.entities.map(\.name) + record.facts.map(\.text)).joined(separator: "\n")
        try db.execute("INSERT INTO activity_fts(activity_id,body) VALUES(?,?)", [.text(record.id), .text(body)])
    }
    private func refreshProjects() throws {
        try db.execute("UPDATE projects SET first_seen=(SELECT MIN(start) FROM activities WHERE project_id=projects.id),last_seen=(SELECT MAX(end) FROM activities WHERE project_id=projects.id),status=CASE WHEN EXISTS(SELECT 1 FROM activities WHERE project_id=projects.id) THEN 'active' ELSE 'configured' END")
    }
    public func search(_ filter: ActivitySearch) throws -> [ActivityRecord] {
        var sql = "SELECT a.payload FROM activities a LEFT JOIN projects p ON a.project_id=p.id WHERE a.start < ? AND a.end > ?"
        var values: [SQLValue] = [.number(filter.to.timeIntervalSince1970), .number(filter.from.timeIntervalSince1970)]
        if let text = filter.text, !text.isEmpty {
            let terms = text.split(whereSeparator: { $0.isWhitespace }).prefix(20).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            sql += " AND a.id IN (SELECT activity_id FROM activity_fts WHERE activity_fts MATCH ?)"; values.append(.text(terms))
        }
        if let project = filter.project { sql += " AND (p.name=? COLLATE NOCASE OR p.id=?)"; values += [.text(project), .text(project)] }
        if let category = filter.category { sql += " AND a.category=?"; values.append(.text(category.rawValue)) }
        if let intent = filter.intent { sql += " AND a.intent=?"; values.append(.text(intent.rawValue)) }
        if let entity = filter.entity {
            sql += " AND a.id IN (SELECT ae.activity_id FROM activity_entities ae JOIN entities e ON ae.entity_id=e.id WHERE e.name=? COLLATE NOCASE)"; values.append(.text(entity))
        }
        if let kind = filter.factKind { sql += " AND EXISTS(SELECT 1 FROM facts f WHERE f.activity_id=a.id AND f.kind=?)"; values.append(.text(kind.rawValue)) }
        sql += " ORDER BY a.start LIMIT ?"; values.append(.number(Double(max(1, min(filter.limit, 10_000)))))
        return try decodeRows(db.rows(sql, values))
    }
    public func records(from: Date, to: Date) throws -> [ActivityRecord] {
        // Reports only load a bounded day/week/month, never all retained observations.
        guard to.timeIntervalSince(from) <= 32 * 86400 else { throw ActivityValidationError.invalid("Reports support periods up to 32 days") }
        return try decodeRows(db.rows("SELECT payload FROM activities WHERE start < ? AND end > ? ORDER BY start", [.number(to.timeIntervalSince1970), .number(from.timeIntervalSince1970)]))
    }
    private func decodeRows(_ rows: [[String?]]) throws -> [ActivityRecord] {
        try rows.compactMap { row in guard let text = row.first.flatMap({ $0 }) else { return nil }; return try JSONDecoder().decode(ActivityRecord.self, from: Data(text.utf8)) }
    }
    public func registeredProjects() throws -> [Project] {
        try db.rows("SELECT name,aliases,repository FROM projects ORDER BY name COLLATE NOCASE").map { row in
            guard let name = row[0], let aliases = row[1] else { throw WorklogError.sqlite("Invalid stored project configuration") }
            return Project(name: name, aliases: try JSONDecoder().decode([String].self, from: Data(aliases.utf8)), repository: row[2])
        }
    }
    public func projectNames() throws -> [String: String] {
        Dictionary(try db.rows("SELECT id,name FROM projects").compactMap { row in guard let id = row[0], let name = row[1] else { return nil }; return (id, name) }, uniquingKeysWith: { first, _ in first })
    }
    public func totals(from: Date, to: Date, dimension: String) throws -> [String: Double] {
        guard ["category", "intent", "project_id"].contains(dimension) else { throw ActivityValidationError.invalid("Invalid aggregate dimension") }
        let rows = try db.rows("SELECT COALESCE(\(dimension),'unassigned'),SUM(MIN(end,?)-MAX(start,?)) FROM activities WHERE start < ? AND end > ? GROUP BY \(dimension)",
                               [.number(to.timeIntervalSince1970), .number(from.timeIntervalSince1970), .number(to.timeIntervalSince1970), .number(from.timeIntervalSince1970)])
        return Dictionary(rows.compactMap { row in guard let key = row[0], let raw = row[1], let total = Double(raw) else { return nil }; return (key, total) }, uniquingKeysWith: +)
    }
    public func correct(id: String, correction: ActivityCorrection) throws {
        try db.transaction {
            guard var record = try decodeRows(db.rows("SELECT payload FROM activities WHERE id=?", [.text(id)])).first else { throw ActivityValidationError.invalid("Unknown activity") }
            if let title = correction.title {
                guard !title.isEmpty, title.count <= 240 else { throw ActivityValidationError.invalid("Invalid corrected title") }
                record.title = safe(title)
            }
            if let category = correction.category { record.category = category }
            if let intent = correction.intent { record.intent = intent }
            if correction.clearProject { record.projectID = nil; record.projectConfidence = 0 }
            else if let project = correction.projectID { record.projectID = project; record.projectConfidence = 1 }
            record.provenance = .userConfirmed
            if correction.category != nil || correction.intent != nil { record.classificationConfidence = 1 }
            record.updatedAt = Date()
            try db.execute("UPDATE activities SET title=?,category=?,intent=?,project_id=?,project_confidence=?,classification_confidence=?,provenance='USER_CONFIRMED',payload=?,updated_at=? WHERE id=?",
                [.text(record.title), .text(record.category.rawValue), .text(record.intent.rawValue), record.projectID.map(SQLValue.text) ?? .null, .number(record.projectConfidence), .number(record.classificationConfidence), .text(try json(record)), .number(record.updatedAt.timeIntervalSince1970), .text(id)])
            try db.execute("UPDATE facts SET project_id=? WHERE activity_id=?", [record.projectID.map(SQLValue.text) ?? .null, .text(id)])
            try db.execute("INSERT INTO corrections(activity_id,timestamp,payload) VALUES(?,?,?)", [.text(id), .number(record.updatedAt.timeIntervalSince1970), .text(safe(try json(correction)))])
            try db.execute("DELETE FROM activity_fts WHERE activity_id=?", [.text(id)])
            try index(record)
            try refreshProjects()
        }
    }
    private func safe(_ value: String) -> String { SecretRedactor().redact(value) }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }

    private static let migration1 = """
    CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE processing_windows(id TEXT PRIMARY KEY,start REAL NOT NULL,end REAL NOT NULL CHECK(end>start),created_at REAL NOT NULL);
    CREATE INDEX windows_time ON processing_windows(start,end);
    CREATE TRIGGER windows_no_overlap BEFORE INSERT ON processing_windows BEGIN
      SELECT RAISE(ABORT,'overlapping processing window') WHERE EXISTS(SELECT 1 FROM processing_windows WHERE start < NEW.end AND end > NEW.start);
    END;
    CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,aliases TEXT NOT NULL,repository TEXT,first_seen REAL,last_seen REAL,status TEXT NOT NULL);
    CREATE TABLE activities(id TEXT PRIMARY KEY,window_id TEXT NOT NULL REFERENCES processing_windows(id),start REAL NOT NULL,end REAL NOT NULL CHECK(end>start),title TEXT NOT NULL,summary TEXT NOT NULL,category TEXT NOT NULL,intent TEXT NOT NULL,project_id TEXT REFERENCES projects(id),confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),classification_confidence REAL NOT NULL CHECK(classification_confidence BETWEEN 0 AND 1),project_confidence REAL NOT NULL CHECK(project_confidence BETWEEN 0 AND 1),source TEXT NOT NULL,provenance TEXT NOT NULL,payload TEXT NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL);
    CREATE INDEX activities_time ON activities(start,end);
    CREATE INDEX activities_project_time ON activities(project_id,start,end);
    CREATE INDEX activities_category_time ON activities(category,start,end);
    CREATE INDEX activities_intent_time ON activities(intent,start,end);
    CREATE TRIGGER activities_no_overlap BEFORE INSERT ON activities BEGIN
      SELECT RAISE(ABORT,'overlapping primary activity') WHERE EXISTS(SELECT 1 FROM activities WHERE start < NEW.end AND end > NEW.start);
      SELECT RAISE(ABORT,'activity outside window') WHERE NOT EXISTS(SELECT 1 FROM processing_windows WHERE id=NEW.window_id AND start<=NEW.start AND end>=NEW.end);
    END;
    CREATE TABLE evidence(id TEXT PRIMARY KEY,window_id TEXT NOT NULL REFERENCES processing_windows(id),timestamp REAL NOT NULL,display TEXT,excerpt TEXT NOT NULL,screenshot_reference TEXT,type TEXT NOT NULL,confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1));
    CREATE INDEX evidence_time ON evidence(timestamp);
    CREATE TABLE activity_evidence(activity_id TEXT REFERENCES activities(id) ON DELETE CASCADE,evidence_id TEXT REFERENCES evidence(id),PRIMARY KEY(activity_id,evidence_id));
    CREATE TABLE entities(id TEXT PRIMARY KEY,kind TEXT NOT NULL,name TEXT NOT NULL);
    CREATE INDEX entities_name ON entities(name COLLATE NOCASE);
    CREATE TABLE activity_entities(activity_id TEXT REFERENCES activities(id) ON DELETE CASCADE,entity_id TEXT REFERENCES entities(id),PRIMARY KEY(activity_id,entity_id));
    CREATE TABLE facts(id TEXT PRIMARY KEY,activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE,kind TEXT NOT NULL,text TEXT NOT NULL,timestamp REAL NOT NULL,project_id TEXT REFERENCES projects(id),confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),provenance TEXT NOT NULL,status TEXT,evidence_ids TEXT NOT NULL);
    CREATE INDEX facts_kind_time ON facts(kind,timestamp);
    CREATE INDEX facts_project_time ON facts(project_id,timestamp);
    PRAGMA user_version=1;
    """
    private static let migration2 = """
    CREATE TABLE corrections(id INTEGER PRIMARY KEY,activity_id TEXT NOT NULL REFERENCES activities(id),timestamp REAL NOT NULL,payload TEXT NOT NULL);
    CREATE VIRTUAL TABLE activity_fts USING fts5(activity_id UNINDEXED,body);
    INSERT INTO activity_fts(activity_id,body) SELECT id,payload FROM activities;
    PRAGMA user_version=2;
    """
    private static let migration3 = """
    ALTER TABLE evidence ADD COLUMN source_reference TEXT;
    ALTER TABLE evidence ADD COLUMN provenance TEXT NOT NULL DEFAULT 'OBSERVED';
    UPDATE evidence SET provenance='INFERRED' WHERE type='visionInference';
    PRAGMA user_version=3;
    """

}

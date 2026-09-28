import Foundation
import CSQLite

final class SQLiteReadConnection {
    private var db: OpaquePointer?

    init(url: URL) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard rc == SQLITE_OK, let connection else {
            let message = connection.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open database"
            if let connection { sqlite3_close(connection) }
            throw WorklogError.sqlite(message)
        }
        db = connection
        sqlite3_busy_timeout(connection, 2_000)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw WorklogError.sqlite("Database is closed") }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw WorklogError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    func errorMessage() -> String {
        guard let db else { return "Database is closed" }
        return String(cString: sqlite3_errmsg(db))
    }
}

@inline(__always)
func sqliteText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let ptr = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: ptr)
}

@inline(__always)
func bindText(_ value: String, to statement: OpaquePointer, index: Int32) -> Bool {
    value.withCString { ptr in
        sqlite3_bind_text(statement, index, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
    }
}

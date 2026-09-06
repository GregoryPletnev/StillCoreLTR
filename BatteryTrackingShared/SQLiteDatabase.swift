import Foundation
import SQLite3

enum SQLiteError: LocalizedError {
    case open(path: String, message: String)
    case prepare(sql: String, message: String)
    case step(sql: String, message: String)
    case exec(sql: String, message: String)

    var errorDescription: String? {
        switch self {
        case .open(let path, let message):
            return "Cannot open \(path): \(message)"
        case .prepare(let sql, let message):
            return "Cannot prepare \(Self.head(of: sql)): \(message)"
        case .step(let sql, let message):
            return "Cannot run \(Self.head(of: sql)): \(message)"
        case .exec(let sql, let message):
            return "Cannot run \(Self.head(of: sql)): \(message)"
        }
    }

    private static func head(of sql: String) -> String {
        let flattened = sql.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return flattened.count <= 60 ? flattened : String(flattened.prefix(60)) + "…"
    }
}

/// Thin wrapper over the system SQLite. Not thread safe: keep one instance per
/// queue. Cross-process access is handled by WAL mode and a busy timeout.
final class SQLiteDatabase {
    private static let transientDestructor = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?

    init(path: String, busyTimeoutMs: Int32 = 5_000) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close_v2(handle)
            throw SQLiteError.open(path: path, message: message)
        }

        self.handle = handle
        sqlite3_busy_timeout(handle, busyTimeoutMs)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    func userVersion() throws -> Int {
        try queryFirst("PRAGMA user_version") { Int($0.int(at: 0)) } ?? 0
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    /// Runs one or more statements that return no rows.
    func execute(_ sql: String) throws {
        guard let handle else { return }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "status \(status)"
            sqlite3_free(errorMessage)
            throw SQLiteError.exec(sql: sql, message: message)
        }
    }

    /// Runs one statement with bound parameters and no result rows.
    func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteError.step(sql: sql, message: lastErrorMessage())
        }
    }

    /// Runs one statement and maps every result row.
    func query<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        row transform: (SQLiteRow) -> T
    ) throws -> [T] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw SQLiteError.step(sql: sql, message: lastErrorMessage())
            }
            results.append(transform(SQLiteRow(statement: statement)))
        }
        return results
    }

    func queryFirst<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        row transform: (SQLiteRow) -> T
    ) throws -> T? {
        try query(sql, parameters, row: transform).first
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer {
        guard let handle else {
            throw SQLiteError.prepare(sql: sql, message: "database is closed")
        }

        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw SQLiteError.prepare(sql: sql, message: lastErrorMessage())
        }

        for (index, parameter) in parameters.enumerated() {
            parameter.bind(to: statement, at: Int32(index + 1))
        }
        return statement
    }

    private func lastErrorMessage() -> String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    fileprivate static var transient: sqlite3_destructor_type { transientDestructor }
}

enum SQLiteValue {
    case integer(Int64)
    case double(Double)
    case text(String)
    case null

    init(_ value: Int) { self = .integer(Int64(value)) }
    init(_ value: Int64) { self = .integer(value) }
    init(_ value: Double) { self = .double(value) }
    init(_ value: String) { self = .text(value) }

    fileprivate func bind(to statement: OpaquePointer, at index: Int32) {
        switch self {
        case .integer(let value):
            sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            sqlite3_bind_double(statement, index, value)
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, SQLiteDatabase.transient)
        case .null:
            sqlite3_bind_null(statement, index)
        }
    }
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func text(at index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    func isNull(at index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}

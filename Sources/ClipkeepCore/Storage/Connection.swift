import Foundation
import SQLCipher

/// Read access to the columns of the current result row.
public struct Row {
    fileprivate let statement: OpaquePointer

    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    public func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    public func optionalText(_ column: Int32) -> String? {
        isNull(column) ? nil : text(column)
    }
}

/// A live SQLite handle. Only reachable inside `Database.read` / `Database.write`,
/// which serialize access, so it is deliberately not `Sendable`.
public final class Connection {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    public var changedRowCount: Int { Int(sqlite3_changes(handle)) }

    public func execute(_ sql: String, _ parameters: [SQLValue] = []) throws {
        _ = try run(sql, parameters) { _ in () }
    }

    public func query<T>(
        _ sql: String, _ parameters: [SQLValue] = [], map: (Row) throws -> T
    ) throws -> [T] {
        try run(sql, parameters, map: map)
    }

    private func run<T>(
        _ sql: String, _ parameters: [SQLValue], map: (Row) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw DatabaseError.prepare(code: sqlite3_errcode(handle), message: message)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in parameters.enumerated() {
            try bind(value, at: Int32(offset + 1), in: statement)
        }

        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try map(Row(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw DatabaseError.step(code: sqlite3_errcode(handle), message: message)
            }
        }
    }

    private func bind(_ value: SQLValue, at index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code: Int32
        switch value {
        case .null: code = sqlite3_bind_null(statement, index)
        case .int(let number): code = sqlite3_bind_int64(statement, index, number)
        case .double(let number): code = sqlite3_bind_double(statement, index, number)
        case .text(let string):
            // Bind by byte length so embedded NUL characters survive.
            var copy = string
            code = copy.withUTF8 { buffer in
                guard let base = buffer.baseAddress else {
                    return sqlite3_bind_text(statement, index, "", 0, transient)
                }
                return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    sqlite3_bind_text(statement, index, $0, Int32(buffer.count), transient)
                }
            }
        case .blob(let data):
            code = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient)
            }
        }
        guard code == SQLITE_OK else { throw DatabaseError.step(code: code, message: message) }
    }

    private var message: String { String(cString: sqlite3_errmsg(handle)) }
}

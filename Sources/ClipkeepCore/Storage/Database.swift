import Foundation
import SQLCipher

/// An encrypted SQLite database (SQLCipher). All access is serialized on one queue.
/// Statements always use bound parameters; never build SQL from user input.
public final class Database: @unchecked Sendable {
    private let queue = DispatchQueue(label: "li.wuermli.clipkeep.database")
    private let connection: Connection

    /// Opens or creates the database at `path` and unlocks it with a 32-byte `key`.
    public init(path: String, key: Data) throws {
        precondition(key.count == 32, "The database key must be 32 bytes")
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw DatabaseError.open(message)
        }
        connection = Connection(handle: handle)

        do {
            let hexKey = key.map { String(format: "%02x", $0) }.joined()
            try connection.execute("PRAGMA key = \"x'\(hexKey)'\"")
            // The first real read fails if the key is wrong or the file is not a database.
            do {
                _ = try connection.query("SELECT count(*) FROM sqlite_master") { $0.int(0) }
            } catch {
                throw DatabaseError.wrongKey
            }
            _ = try connection.query("PRAGMA journal_mode = WAL") { $0.text(0) }
            try connection.execute("PRAGMA foreign_keys = ON")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close(connection.handle)
    }

    public func read<T>(_ body: (Connection) throws -> T) throws -> T {
        try queue.sync { try body(connection) }
    }

    /// Runs `body` in a transaction that rolls back when it throws.
    public func write<T>(_ body: (Connection) throws -> T) throws -> T {
        try queue.sync {
            try connection.execute("BEGIN IMMEDIATE")
            do {
                let result = try body(connection)
                try connection.execute("COMMIT")
                return result
            } catch {
                try? connection.execute("ROLLBACK")
                throw error
            }
        }
    }
}

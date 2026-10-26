import Foundation
import SQLCipher

/// An encrypted SQLite database (SQLCipher). All access is serialized on one queue.
/// Statements always use bound parameters; never build SQL from user input.
/// The API is not re-entrant: do not call `read` or `write` from inside their closures.
public final class Database: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Void>()
    private let queue = DispatchQueue(label: "li.wuermli.clipkeep.database")
    private let connection: Connection

    /// Opens or creates the database at `path` and unlocks it with a 32-byte `key`.
    public init(path: String, key: Data) throws {
        precondition(key.count == 32, "The database key must be 32 bytes")
        var opened: OpaquePointer?
        guard sqlite3_open(path, &opened) == SQLITE_OK, let handle = opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(opened)
            throw DatabaseError.open(message)
        }

        // All fallible setup happens before `self.connection` is assigned, so a failure closes
        // the handle exactly once and never runs `deinit`.
        let setup = Connection(handle: handle)
        do {
            sqlite3_busy_timeout(handle, 5_000)
            let hexKey = key.map { String(format: "%02x", $0) }.joined()
            try setup.execute("PRAGMA key = \"x'\(hexKey)'\"")
            let cipherVersion = try setup.query("PRAGMA cipher_version") { $0.text(0) }
            guard cipherVersion.first?.isEmpty == false else {
                throw DatabaseError.open("SQLCipher is not the linked SQLite library")
            }
            try Self.verifyKey(setup)
            _ = try setup.query("PRAGMA journal_mode = WAL") { $0.text(0) }
            try setup.execute("PRAGMA foreign_keys = ON")
            // REPLACE conflicts delete rows implicitly; the index triggers must fire for those too.
            try setup.execute("PRAGMA recursive_triggers = ON")
        } catch {
            sqlite3_close(handle)
            throw error
        }
        connection = setup
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        sqlite3_close(connection.handle)
    }

    public func read<T>(_ body: (Connection) throws -> T) throws -> T {
        try onQueue { try body(connection) }
    }

    /// Runs `body` in a transaction that rolls back when it throws.
    public func write<T>(_ body: (Connection) throws -> T) throws -> T {
        try onQueue {
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

    private func onQueue<T>(_ work: () throws -> T) throws -> T {
        precondition(
            DispatchQueue.getSpecific(key: Self.queueKey) == nil,
            "Database.read/write must not be nested")
        return try queue.sync(execute: work)
    }

    /// A wrong key makes the first read fail with SQLITE_NOTADB. Other failures (a lock, I/O)
    /// are passed through so callers never mistake them for a wrong key.
    private static func verifyKey(_ connection: Connection) throws {
        do {
            _ = try connection.query("SELECT count(*) FROM sqlite_master") { $0.int(0) }
        } catch DatabaseError.step(let code, _) where code == SQLITE_NOTADB {
            throw DatabaseError.wrongKey
        } catch DatabaseError.prepare(let code, _) where code == SQLITE_NOTADB {
            throw DatabaseError.wrongKey
        }
    }
}

import Foundation

/// Small key-value settings in the encrypted database.
public struct SettingsStore: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func string(_ key: String) throws -> String? {
        try database.read { connection in
            try connection.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) {
                $0.text(0)
            }.first
        }
    }

    public func set(_ value: String, for key: String) throws {
        try database.write { connection in
            try connection.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                [.text(key), .text(value)])
        }
    }

    public func bool(_ key: String) throws -> Bool? {
        try string(key).map { $0 == "1" }
    }

    public func set(_ value: Bool, for key: String) throws {
        try set(value ? "1" : "0", for: key)
    }
}

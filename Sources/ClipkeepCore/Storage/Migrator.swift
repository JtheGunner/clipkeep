/// One schema step. `version` numbers must be unique and strictly increasing.
public struct Migration: Sendable {
    public let version: Int
    public let statements: [String]

    public init(version: Int, statements: [String]) {
        self.version = version
        self.statements = statements
    }
}

/// Applies pending migrations in order, each in its own transaction, tracked by `user_version`.
public struct Migrator: Sendable {
    private let migrations: [Migration]

    public init(migrations: [Migration]) {
        precondition(
            zip(migrations, migrations.dropFirst()).allSatisfy { $0.version < $1.version },
            "Migration versions must be strictly increasing")
        self.migrations = migrations
    }

    public func migrate(_ database: Database) throws {
        let supported = migrations.last?.version ?? 0
        let found = try Self.userVersion(database)
        guard found <= supported else {
            throw DatabaseError.schemaTooNew(found: found, supported: supported)
        }

        for migration in migrations {
            do {
                try database.write { connection in
                    // Re-read inside the transaction so a concurrent process cannot apply it twice.
                    let current = try connection.query("PRAGMA user_version") { Int($0.int(0)) }
                    guard migration.version > (current.first ?? 0) else { return }
                    for statement in migration.statements {
                        try connection.execute(statement)
                    }
                    // PRAGMA does not accept bound parameters; the value is our own integer.
                    try connection.execute("PRAGMA user_version = \(migration.version)")
                }
            } catch {
                throw DatabaseError.migration(version: migration.version, message: "\(error)")
            }
        }
    }

    private static func userVersion(_ database: Database) throws -> Int {
        try database.read { connection in
            try connection.query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
        }
    }
}

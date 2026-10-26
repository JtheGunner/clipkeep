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
        let current = try database.read { connection in
            try connection.query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
        }
        for migration in migrations where migration.version > current {
            do {
                try database.write { connection in
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
}

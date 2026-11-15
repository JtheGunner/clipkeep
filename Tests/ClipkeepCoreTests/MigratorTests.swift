import Testing

@testable import ClipkeepCore

@Suite struct MigratorTests {
    private func userVersion(_ database: Database) throws -> Int {
        try database.read { try $0.query("PRAGMA user_version") { Int($0.int(0)) } }.first ?? -1
    }

    @Test func freshDatabaseReachesLatestVersion() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }

        let database = try temp.open()

        #expect(try userVersion(database) == Schema.latestVersion)
        let tables = try database.read {
            try $0.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) }
        }
        for name in ["contents", "copy_events", "sessions", "topics", "entities", "settings"] {
            #expect(tables.contains(name))
        }
    }

    @Test func runningTwiceIsIdempotent() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()

        try Schema.migrator.migrate(database)

        #expect(try userVersion(database) == Schema.latestVersion)
    }

    @Test func onlyPendingMigrationsRun() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        let first = Migration(version: 1, statements: ["CREATE TABLE a (id INTEGER)"])
        let second = Migration(version: 2, statements: ["CREATE TABLE b (id INTEGER)"])
        try Migrator(migrations: [first]).migrate(database)

        try Migrator(migrations: [first, second]).migrate(database)

        #expect(try userVersion(database) == 2)
    }

    @Test func failingMigrationRollsBackAndKeepsVersion() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        let broken = Migration(
            version: 1, statements: ["CREATE TABLE a (id INTEGER)", "THIS IS NOT SQL"])

        #expect(throws: DatabaseError.self) {
            try Migrator(migrations: [broken]).migrate(database)
        }

        #expect(try userVersion(database) == 0)
        let tables = try database.read {
            try $0.query("SELECT name FROM sqlite_master WHERE name = 'a'") { $0.text(0) }
        }
        #expect(tables.isEmpty)
    }

    @Test func stepRunsAfterTheStatements() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        let migration = Migration(
            version: 1, statements: ["CREATE TABLE a (id INTEGER)"],
            step: { connection in try connection.execute("INSERT INTO a(id) VALUES (7)") })

        try Migrator(migrations: [migration]).migrate(database)

        #expect(try userVersion(database) == 1)
        let ids = try database.read { try $0.query("SELECT id FROM a") { $0.int(0) } }
        #expect(ids == [7])
    }

    @Test func failingStepRollsBackAndKeepsVersion() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        try Migrator(migrations: Array(Schema.migrations.prefix(12))).migrate(database)
        let broken = Migration(
            version: 13, statements: ["CREATE TABLE a (id INTEGER)"],
            step: { _ in throw StepError.failed })

        #expect(throws: DatabaseError.self) {
            try Migrator(migrations: Array(Schema.migrations.prefix(12)) + [broken]).migrate(
                database)
        }

        #expect(try userVersion(database) == 12)
        let tables = try database.read {
            try $0.query("SELECT name FROM sqlite_master WHERE name = 'a'") { $0.text(0) }
        }
        #expect(tables.isEmpty)
    }

    private enum StepError: Error {
        case failed
    }
}

@Suite struct MigratorGuardTests {
    @Test func newerSchemaThanSupportedIsRejected() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        try database.write { try $0.execute("PRAGMA user_version = 99") }

        #expect(throws: DatabaseError.schemaTooNew(found: 99, supported: Schema.latestVersion)) {
            try Schema.migrator.migrate(database)
        }
    }
}

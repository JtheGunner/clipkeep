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

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

    /// The real migration 13, failing at its very end: everything it did is rolled back and the
    /// version 12 snippets table is left as it was.
    @Test func failingSnippetMigrationLeavesVersion12Intact() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        let version12 = Array(Schema.migrations.prefix(12))
        try Migrator(migrations: version12).migrate(database)
        let text = "diff <(ls /a) <(ls /b)"
        try database.write { connection in
            try connection.execute(
                """
                INSERT INTO snippets
                    (text, hash, language, origin, app_name, search_text, created_at,
                     last_copied_at, copy_count)
                VALUES (?, ?, 'shell', 'auto', NULL, ?, 1, 2, 1)
                """,
                [.text(text), .text(ContentHashing.exactHash(text)), .text(SearchText.fold(text))])
        }
        let real = try #require(Schema.migrations.last)
        #expect(real.version == 13)
        let broken = Migration(
            version: 13, statements: real.statements,
            step: { connection in
                try real.step?(connection)
                throw StepError.failed
            })

        #expect(throws: DatabaseError.self) {
            try Migrator(migrations: version12 + [broken]).migrate(database)
        }

        #expect(try userVersion(database) == 12)
        let (columns, tables, rows) = try database.read { connection in
            (
                try connection.query("SELECT name FROM pragma_table_info('snippets')") {
                    $0.text(0)
                },
                try connection.query(
                    """
                    SELECT name FROM sqlite_master
                    WHERE name IN ('snippet_variants', 'snippet_variant_seed', 'snippets_new')
                    UNION SELECT name FROM sqlite_temp_master
                    """
                ) { $0.text(0) },
                try connection.query("SELECT text, hash FROM snippets") {
                    [$0.text(0), $0.text(1)]
                }
            )
        }
        #expect(columns.contains("hash"))
        #expect(!columns.contains("shape_hash"))
        #expect(tables.isEmpty)
        #expect(rows == [[text, ContentHashing.exactHash(text)]])
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

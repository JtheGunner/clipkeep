import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetEvaluationTests {
    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let store: ContentStore

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
        }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func acceptsSQLAndSkipsDeletedAndSecretEntries() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let query = "SELECT id, name FROM customers WHERE active = 1;"
        _ = try fixture.store.record(text: query, copiedAt: base)
        _ = try fixture.store.record(text: "ls", copiedAt: base.addingTimeInterval(1))
        let deleted = try fixture.store.record(
            text: "docker compose up -d --build", copiedAt: base.addingTimeInterval(2))
        try fixture.database.write { connection in
            try connection.execute(
                "UPDATE contents SET deleted_at = ? WHERE id = ?",
                [SQLValue(base), .int(deleted.contentID)])
        }
        _ = try fixture.store.record(
            text: "[secret parked]", copiedAt: base.addingTimeInterval(3), kind: .secret)

        let report = try SnippetEvaluation.run(database: fixture.database)

        #expect(report.examined == 2)
        #expect(report.accepted.map(\.text) == [query])
        #expect(report.accepted.map(\.language) == [.sql])
        #expect(!report.rejectedCodeLike.contains { $0.text == "ls" })
    }

    @Test func listsMultiLineNonCodeTextAsRejectedCodeLike() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let notes = "Dear team\nthe meeting moved\nto friday"
        _ = try fixture.store.record(text: notes, copiedAt: base)

        let report = try SnippetEvaluation.run(database: fixture.database)

        #expect(report.accepted.isEmpty)
        #expect(report.rejectedCodeLike.map(\.text) == [notes])
        #expect(report.rejectedCodeLike.map(\.language) == [nil])
    }

    @Test func limitsTheRejectedListAndKeepsNewestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for index in 0..<5 {
            _ = try fixture.store.record(
                text: "Note \(index)\nsecond line\nthird line",
                copiedAt: base.addingTimeInterval(Double(index)))
        }

        let report = try SnippetEvaluation.run(database: fixture.database, rejectedLimit: 2)

        #expect(report.examined == 5)
        #expect(report.rejectedCodeLike.count == 2)
        #expect(report.rejectedCodeLike.first?.text.hasPrefix("Note 4") == true)
    }

    @Test func rendersGroupedPlainTextReport() {
        let report = SnippetEvaluationReport(
            accepted: [.init(language: .shell, text: "git status -s")],
            rejectedCodeLike: [.init(language: nil, text: "a\nb\nc")], examined: 7)

        let text = report.rendered()

        #expect(text.contains("Examined 7"))
        #expect(text.contains("Accepted (1)"))
        #expect(text.contains("[shell]"))
        #expect(text.contains("Rejected but code-like (1)"))
        #expect(text.contains("git status -s"))
    }

    @Test func readOnlyConnectionRejectsWritesAndLeavesTheFileUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "SELECT 1 FROM dual;", copiedAt: base)
        _ = try fixture.database.read {
            try $0.query("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
        }
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.temp.path))
        let modified =
            try FileManager.default.attributesOfItem(atPath: fixture.temp.path)[
                .modificationDate] as? Date

        let readOnly = try Database(path: fixture.temp.path, key: fixture.temp.key, readOnly: true)
        let report = try SnippetEvaluation.run(database: readOnly)
        #expect(report.examined == 1)
        #expect(throws: (any Error).self) {
            try readOnly.write { try $0.execute("DELETE FROM contents") }
        }

        let after = try Data(contentsOf: URL(fileURLWithPath: fixture.temp.path))
        #expect(after == before)
        let modifiedAfter =
            try FileManager.default.attributesOfItem(atPath: fixture.temp.path)[
                .modificationDate] as? Date
        #expect(modifiedAfter == modified)
    }

    @Test func readOnlyOpenOfAMissingFileCreatesNothing() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }

        #expect(throws: (any Error).self) {
            _ = try Database(path: temp.path, key: temp.key, readOnly: true)
        }
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func missingSchemaFailsWithoutDetailsOrMigration() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let unmigrated = try temp.open(migrated: false)

        #expect(throws: SnippetEvaluationError.unreadableHistory) {
            _ = try SnippetEvaluation.run(database: unmigrated)
        }
        let tables = try unmigrated.read {
            try $0.query("SELECT count(*) FROM sqlite_master") { $0.int(0) }
        }
        #expect(tables == [0])
    }
}

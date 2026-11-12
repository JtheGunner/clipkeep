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
}

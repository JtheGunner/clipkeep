import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetPromoterTests {
    private static let sql = "SELECT id, name FROM customers WHERE active = 1;"
    private static let yaml = "services:\n  web:\n    image: nginx\n    ports:\n      - 8080:80"
    private static let secretShell = "DB_PASSWORD=hunter2hunter2 ./scripts/test.sh --filter Core"

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let history: ContentStore
        let snippets: SnippetStore
        let promoter: SnippetPromoter

        init(anonymizer: SnippetAnonymizer = SnippetAnonymizer(), pageSize: Int = 500) throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            history = ContentStore(database: database)
            snippets = SnippetStore(database: database)
            promoter = SnippetPromoter(
                database: database, store: snippets, anonymizer: anonymizer, pageSize: pageSize)
        }

        /// The kind is fixed so the classifier never turns a synthetic example into a secret row.
        func record(_ text: String, at date: Date, kind: ContentKind = .text) throws -> Int64 {
            try history.record(text: text, copiedAt: date, kind: kind).contentID
        }

        func markDeleted(_ contentID: Int64, at date: Date) throws {
            try database.write { connection in
                try connection.execute(
                    "UPDATE contents SET deleted_at = ? WHERE id = ?",
                    [SQLValue(date), .int(contentID)])
            }
        }

        /// Proves the secret value reached neither the stored text, the folded search text nor
        /// the full-text index.
        func expectNoTrace(of value: String) throws {
            #expect(try snippets.list(limit: 100).allSatisfy { !$0.text.contains(value) })
            let searchTexts = try database.read { connection in
                try connection.query("SELECT search_text FROM snippets") { $0.text(0) }
            }
            #expect(!searchTexts.isEmpty)
            #expect(searchTexts.allSatisfy { !$0.contains(value) })
            #expect(try snippets.search(value, limit: 10).isEmpty)
        }

        func historyRows() throws -> [String] {
            try database.read { connection in
                try connection.query(
                    """
                    SELECT id || '|' || text || '|' || kind || '|' || last_copied_at || '|' ||
                        coalesce(deleted_at, '') FROM contents ORDER BY id
                    """
                ) { $0.text(0) }
            }
        }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Promote

    @Test func promoteStoresTheAnonymisedTextAsHistoryOrigin() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try fixture.record(Self.secretShell, at: base)

        let outcome = try fixture.promoter.promote(contentID: id, language: nil)

        guard case .stored(let snippetID) = outcome else {
            Issue.record("expected stored, got \(outcome)")
            return
        }
        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.map(\.id) == [snippetID])
        #expect(stored.first?.origin == .history)
        #expect(stored.first?.language == .shell)
        #expect(stored.first?.text.contains("<VALUE>") == true)
        #expect(stored.first?.text.contains("hunter2hunter2") == false)
        try fixture.expectNoTrace(of: "hunter2")
    }

    @Test func promoteOfAnExistingSnippetBumpsIt() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try fixture.record("ls", at: base)
        guard
            case .inserted(let snippetID) = try fixture.snippets.add(
                text: "ls", language: .yaml, origin: .auto, appName: "Terminal", at: base)
        else {
            Issue.record("expected the snippet to be inserted")
            return
        }

        let outcome = try fixture.promoter.promote(contentID: id, language: .shell)

        #expect(outcome == .stored(snippetID))
        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.count == 1)
        #expect(stored.first?.copyCount == 2)
        // The row is bumped, not rewritten: its language and origin stay as stored.
        #expect(stored.first?.language == .yaml)
        #expect(stored.first?.origin == .auto)
        #expect(stored.first?.appName == "Terminal")
    }

    @Test func promoteTakesTheRecognisedLanguage() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try fixture.record(Self.sql, at: base)

        #expect(try fixture.promoter.promote(contentID: id, language: nil) != .needsLanguage)
        #expect(try fixture.snippets.list(limit: 10).map(\.language) == [.sql])
    }

    @Test func promoteWithoutRecognisedLanguageAsksForOne() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try fixture.record("ls", at: base)

        #expect(try fixture.promoter.promote(contentID: id, language: nil) == .needsLanguage)
        #expect(try fixture.snippets.count() == 0)

        let outcome = try fixture.promoter.promote(contentID: id, language: .shell)
        guard case .stored = outcome else {
            Issue.record("expected stored, got \(outcome)")
            return
        }
        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.map(\.text) == ["ls"])
        #expect(stored.map(\.language) == [.shell])
        #expect(stored.map(\.origin) == [.history])
    }

    @Test func promoteIgnoresDeletedAndSecretPlaceholderEntries() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let deleted = try fixture.record(Self.sql, at: base)
        try fixture.markDeleted(deleted, at: base)
        let parked = try fixture.record(
            "[secret parked]", at: base.addingTimeInterval(1), kind: .secret)

        #expect(try fixture.promoter.promote(contentID: deleted, language: .sql) == .unavailable)
        #expect(try fixture.promoter.promote(contentID: parked, language: .shell) == .unavailable)
        #expect(try fixture.promoter.promote(contentID: 9_999, language: .shell) == .unavailable)
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func promoteRevivesADeletedSnippet() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try fixture.record(Self.sql, at: base)
        guard
            case .inserted(let snippetID) = try fixture.snippets.add(
                text: Self.sql, language: .sql, origin: .auto, appName: nil, at: base)
        else {
            Issue.record("expected the snippet to be inserted")
            return
        }
        #expect(try fixture.snippets.delete(id: snippetID))

        let outcome = try fixture.promoter.promote(contentID: id, language: nil)

        guard case .stored = outcome else {
            Issue.record("expected stored, got \(outcome)")
            return
        }
        #expect(try fixture.snippets.list(limit: 10).map(\.text) == [Self.sql])
        // The rejection is gone, so live capture may bump the snippet again.
        #expect(
            try fixture.snippets.add(text: Self.sql, language: .sql, origin: .auto, appName: nil)
                != .rejected)
    }

    @Test func promoteRefusesTextWithAResidualSecret() throws {
        // An anonymiser that lets the value through simulates a redaction that missed a secret.
        let lenient = SnippetAnonymizer(
            detector: SecretDetector(allowedHashes: [ContentHashing.exactHash("hunter2hunter2")]))
        let fixture = try Fixture(anonymizer: lenient)
        defer { fixture.temp.remove() }
        let id = try fixture.record(Self.secretShell, at: base)

        #expect(try fixture.promoter.promote(contentID: id, language: .shell) == .residualSecret)
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func promoteRefusesSourceTextAboveTheReadLimit() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let limit = SnippetFilter.Threshold.maximumBytes * SnippetCapture.sizeSlackFactor
        let huge = String(repeating: "a", count: limit + 1)
        let id = try fixture.record(huge, at: base)

        #expect(try fixture.promoter.promote(contentID: id, language: .shell) == .tooLarge)
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func promoteRefusesAnonymisedTextAboveTheSnippetSize() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let line = "echo build step done\n"
        // Between the filter's byte cap and the read limit: only the anonymised-size guard trips.
        let huge = String(repeating: line, count: SnippetFilter.Threshold.maximumBytes / 10)
        #expect(huge.utf8.count > SnippetFilter.Threshold.maximumBytes)
        #expect(
            huge.utf8.count
                <= SnippetFilter.Threshold.maximumBytes * SnippetCapture.sizeSlackFactor)
        let id = try fixture.record(huge, at: base)

        #expect(try fixture.promoter.promote(contentID: id, language: .shell) == .tooLarge)
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func promoteLeavesTheHistoryUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try fixture.record(Self.secretShell, at: base)
        let before = try fixture.historyRows()

        _ = try fixture.promoter.promote(contentID: id, language: nil)

        #expect(try fixture.historyRows() == before)
    }

    // MARK: - Backfill

    @Test func backfillAddsOnlyAcceptedEntries() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.record(Self.sql, at: base)
        _ = try fixture.record("ls", at: base.addingTimeInterval(1))
        let deleted = try fixture.record(
            "docker compose up -d --build", at: base.addingTimeInterval(2))
        try fixture.markDeleted(deleted, at: base.addingTimeInterval(3))
        _ = try fixture.record(
            "Let us meet tomorrow at noon to talk about the plan.", at: base.addingTimeInterval(4))

        let report = try fixture.promoter.backfill()

        #expect(report == BackfillReport(examined: 3, added: 1))
        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.map(\.text) == [Self.sql])
        #expect(stored.map(\.origin) == [.history])
        #expect(stored.map(\.language) == [.sql])
        #expect(stored.first?.appName == nil)
        #expect(stored.first?.lastCopiedAt == base)
    }

    @Test func backfillSkipsSecretRows() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        // A parked secret's row holds a placeholder; even code-like text there is never read.
        _ = try fixture.record(Self.sql, at: base, kind: .secret)

        let report = try fixture.promoter.backfill()

        #expect(report == BackfillReport(examined: 0, added: 0))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func backfillStoresSecretBearingTextAnonymisedOnly() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.record(Self.secretShell, at: base)

        #expect(try fixture.promoter.backfill().added == 1)

        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.first?.text.contains("<VALUE>") == true)
        #expect(stored.allSatisfy { !$0.text.contains("hunter2") })
        try fixture.expectNoTrace(of: "hunter2")
    }

    @Test func backfillDropsTextWithAResidualSecret() throws {
        let lenient = SnippetAnonymizer(
            detector: SecretDetector(allowedHashes: [ContentHashing.exactHash("hunter2hunter2")]))
        let fixture = try Fixture(anonymizer: lenient)
        defer { fixture.temp.remove() }
        _ = try fixture.record(Self.secretShell, at: base)
        _ = try fixture.record(Self.sql, at: base.addingTimeInterval(1))

        let report = try fixture.promoter.backfill()

        #expect(report == BackfillReport(examined: 2, added: 1))
        #expect(try fixture.snippets.list(limit: 10).map(\.text) == [Self.sql])
    }

    @Test func backfillIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.record(Self.sql, at: base)
        _ = try fixture.record(Self.yaml, at: base.addingTimeInterval(1))
        #expect(try fixture.promoter.backfill().added == 2)

        let report = try fixture.promoter.backfill()

        #expect(report == BackfillReport(examined: 2, added: 0))
        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.count == 2)
        // A repeated run must not count as copies.
        #expect(stored.allSatisfy { $0.copyCount == 1 })
    }

    @Test func backfillLeavesExistingSnippetsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.record(Self.sql, at: base)
        let captured = base.addingTimeInterval(60)
        _ = try fixture.snippets.add(
            text: Self.sql, language: .sql, origin: .auto, appName: "Terminal", at: captured)

        #expect(try fixture.promoter.backfill() == BackfillReport(examined: 1, added: 0))

        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.map(\.copyCount) == [1])
        #expect(stored.map(\.origin) == [.auto])
        #expect(stored.map(\.lastCopiedAt) == [captured])
    }

    @Test func backfillRespectsRejections() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.record(Self.sql, at: base)
        _ = try fixture.promoter.backfill()
        let snippet = try #require(try fixture.snippets.list(limit: 10).first)
        #expect(try fixture.snippets.delete(id: snippet.id))

        let report = try fixture.promoter.backfill()

        #expect(report == BackfillReport(examined: 1, added: 0))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func backfillPagesThroughTheWholeHistory() throws {
        let fixture = try Fixture(pageSize: 2)
        defer { fixture.temp.remove() }
        for index in 0..<5 {
            _ = try fixture.record(
                "SELECT id FROM table_\(index) WHERE active = 1;",
                at: base.addingTimeInterval(Double(index)))
        }

        #expect(try fixture.promoter.backfill() == BackfillReport(examined: 5, added: 5))
    }

    @Test func backfillSkipsTextFarAboveTheSnippetSize() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let huge = String(
            repeating: "SELECT id FROM users;\n", count: SnippetFilter.Threshold.maximumBytes / 4)
        _ = try fixture.record(huge, at: base)

        #expect(try fixture.promoter.backfill() == BackfillReport(examined: 1, added: 0))
    }

    @Test func backfillLeavesTheHistoryUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.record(Self.sql, at: base)
        _ = try fixture.record(Self.secretShell, at: base.addingTimeInterval(1))
        let before = try fixture.historyRows()

        _ = try fixture.promoter.backfill()

        #expect(try fixture.historyRows() == before)
    }
}

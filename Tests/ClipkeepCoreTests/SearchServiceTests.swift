import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SearchServiceTests {
    private struct Fixture {
        let temp: TemporaryDatabase
        let store: ContentStore
        let search: SearchService
        let database: Database

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
            search = SearchService(database: database)
        }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func substringInsideAnIdentifierIsFound() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "func getUserData() -> User")
        _ = try fixture.store.record(text: "something unrelated")

        let hits = try fixture.search.search("serDa")

        #expect(hits.map(\.text) == ["func getUserData() -> User"])
    }

    @Test func searchIgnoresCase() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "Hello World")

        #expect(try fixture.search.search("hello wor").count == 1)
    }

    @Test func allTermsMustMatch() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "docker compose up")
        _ = try fixture.store.record(text: "docker build")

        let hits = try fixture.search.search("docker compose")

        #expect(hits.map(\.text) == ["docker compose up"])
    }

    @Test func shortTermsFallBackToSubstringMatch() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "ls -la /tmp")
        _ = try fixture.store.record(text: "cd /var")

        #expect(try fixture.search.search("ls").map(\.text) == ["ls -la /tmp"])
        #expect(try fixture.search.search("ls tmp").map(\.text) == ["ls -la /tmp"])
    }

    @Test func queryOperatorsStayLiteral() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "a OR b NOT c \"quoted\" (x*)")

        #expect(try fixture.search.search("\"quoted\"").count == 1)
        #expect(try fixture.search.search("OR b NOT").count == 1)
        #expect(try fixture.search.search("x*)").count == 1)
        #expect(try fixture.search.search("\"").count == 1)
    }

    @Test func emptyQueryReturnsNewestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "old", copiedAt: base)
        _ = try fixture.store.record(text: "new", copiedAt: base.addingTimeInterval(100))

        #expect(try fixture.search.search("").map(\.text) == ["new", "old"])
    }

    @Test func betterMatchesRankFirst() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 20)
        _ = try fixture.store.record(text: filler + "needle " + filler, copiedAt: base)
        _ = try fixture.store.record(text: "needle", copiedAt: base)

        #expect(try fixture.search.search("needle").first?.text == "needle")
    }

    @Test func filtersByAppAndTimeAndKind() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let safari = CopyContext(appBundleID: "com.apple.Safari", appName: "Safari")
        let xcode = CopyContext(appBundleID: "com.apple.dt.Xcode", appName: "Xcode")
        _ = try fixture.store.record(text: "alpha one", copiedAt: base, context: safari)
        _ = try fixture.store.record(
            text: "alpha two", copiedAt: base.addingTimeInterval(1000), context: xcode)

        let bySafari = try fixture.search.search(
            "alpha", filter: SearchFilter(appBundleID: "com.apple.Safari"))
        let late = try fixture.search.search(
            "alpha", filter: SearchFilter(copiedAfter: base.addingTimeInterval(500)))
        let early = try fixture.search.search(
            "alpha", filter: SearchFilter(copiedBefore: base.addingTimeInterval(500)))
        let combined = try fixture.search.search(
            "alpha",
            filter: SearchFilter(
                appBundleID: "com.apple.Safari", copiedAfter: base.addingTimeInterval(500)))
        let wrongKind = try fixture.search.search("alpha", filter: SearchFilter(kind: "url"))

        #expect(bySafari.map(\.text) == ["alpha one"])
        #expect(late.map(\.text) == ["alpha two"])
        #expect(early.map(\.text) == ["alpha one"])
        #expect(combined.isEmpty)
        #expect(wrongKind.isEmpty)
    }

    @Test func filtersBySession() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let recorded = try fixture.store.record(text: "in a session", copiedAt: base)
        _ = try fixture.store.record(text: "outside a session", copiedAt: base)
        try fixture.database.write {
            try $0.execute("INSERT INTO sessions (id, started_at, ended_at) VALUES (7, 0, 0)")
            try $0.execute(
                "UPDATE copy_events SET session_id = 7 WHERE id = ?", [.int(recorded.eventID)])
        }

        let hits = try fixture.search.search("session", filter: SearchFilter(sessionID: 7))

        #expect(hits.map(\.text) == ["in a session"])
    }

    @Test func hitCarriesOccurrencesAndLatestContext() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(
            text: "repeated", copiedAt: base, context: CopyContext(appName: "Old"))
        _ = try fixture.store.record(
            text: "repeated", copiedAt: base.addingTimeInterval(60),
            context: CopyContext(appName: "Safari", windowTitle: "Docs", url: "https://a.example"))

        let hit = try #require(try fixture.search.search("repeated").first)

        #expect(hit.occurrenceCount == 2)
        #expect(hit.lastAppName == "Safari")
        #expect(hit.lastWindowTitle == "Docs")
        #expect(hit.lastURL == "https://a.example")
        #expect(hit.lastCopiedAt == base.addingTimeInterval(60))
    }

    @Test func limitIsHonored() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for index in 0..<10 { _ = try fixture.store.record(text: "common text \(index)") }

        #expect(try fixture.search.search("common", filter: SearchFilter(limit: 3)).count == 3)
    }

    @Test func deletedAndUpdatedContentLeavesTheIndex() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let first = try fixture.store.record(text: "findable phrase")
        let second = try fixture.store.record(text: "before edit")

        try fixture.database.write {
            try $0.execute("DELETE FROM contents WHERE id = ?", [.int(first.contentID)])
            try $0.execute(
                "UPDATE contents SET text = 'after edit', search_text = 'after edit' WHERE id = ?",
                [.int(second.contentID)])
        }

        #expect(try fixture.search.search("findable").isEmpty)
        #expect(try fixture.search.search("before").isEmpty)
        #expect(try fixture.search.search("after").count == 1)
    }

    @Test func existingRowsAreIndexedWhenMigratingFromVersionOne() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        try Migrator(migrations: [Schema.migrations[0]]).migrate(database)
        try database.write {
            try $0.execute(
                "INSERT INTO contents (hash, normalized_hash, text, first_seen_at) VALUES ('h', 'n', 'legacy entry', 0)"
            )
        }

        try Schema.migrator.migrate(database)

        #expect(try SearchService(database: database).search("legacy").count == 1)
    }

    @Test func literalAndUnicodeEdgeCasesBehave() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "Größe Übung ÄÖ")
        _ = try fixture.store.record(text: "Mu\u{0308}ller und Müller")

        #expect(try fixture.search.search("üb").count == 1)
        #expect(try fixture.search.search("äö").count == 1)
        #expect(try fixture.search.search("ÜBUNG").count == 1)
        #expect(try fixture.search.search("Müller").count == 1)
        #expect(try fixture.search.search("mül").count == 1)
        #expect(try fixture.search.search("a\u{0}bcd").isEmpty)
        #expect(try fixture.search.search("\u{0}").count == 2)
    }

    @Test func nonPositiveLimitReturnsNothing() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "something")

        #expect(try fixture.search.search("", filter: SearchFilter(limit: 0)).isEmpty)
        #expect(try fixture.search.search("", filter: SearchFilter(limit: -5)).isEmpty)
    }

    @Test func replaceConflictsKeepTheIndexConsistent() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let recorded = try fixture.store.record(text: "original replaceable")

        try fixture.database.write {
            try $0.execute(
                """
                INSERT OR REPLACE INTO contents
                    (id, hash, normalized_hash, text, search_text, first_seen_at)
                VALUES (?, 'new', 'new', 'brandnew', 'brandnew', 0)
                """, [.int(recorded.contentID)])
        }

        #expect(try fixture.search.search("original").isEmpty)
        #expect(try fixture.search.search("brandnew").count == 1)
        try fixture.database.write {
            try $0.execute("INSERT INTO contents_fts(contents_fts) VALUES ('integrity-check')")
        }
    }

    @Test func realisticLargeDatabaseStaysFast() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        let apps = ["com.apple.Safari", "com.apple.dt.Xcode", "com.apple.Terminal"]
        try fixture.database.write { connection in
            for index in 0..<100_000 {
                let text = "\(words[index % 8]) \(words[(index / 8) % 8]) item-\(index) payload"
                try connection.execute(
                    """
                    INSERT INTO contents
                        (hash, normalized_hash, text, search_text, first_seen_at, last_copied_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text("h\(index)"), .text("n\(index)"), .text(text),
                        .text(SearchText.fold(text)), .double(Double(index)),
                        .double(Double(index)),
                    ])
                let contentID = connection.lastInsertRowID
                for copy in 0..<2 {
                    try connection.execute(
                        """
                        INSERT INTO copy_events (content_id, copied_at, app_bundle_id, app_name)
                        VALUES (?, ?, ?, ?)
                        """,
                        [
                            .int(contentID), .double(Double(index + copy)),
                            .text(apps[index % 3]), .text("App"),
                        ])
                }
            }
        }

        func measure(_ query: String, _ filter: SearchFilter = SearchFilter()) throws -> Double {
            let started = Date()
            _ = try fixture.search.search(query, filter: filter)
            return Date().timeIntervalSince(started)
        }

        let timings: [(String, Double)] = [
            ("unique term", try measure("item-99999")),
            ("empty query", try measure("")),
            ("short term", try measure("a")),
            ("broad term", try measure("payload")),
            ("empty + app filter", try measure("", SearchFilter(appBundleID: "com.apple.Safari"))),
            (
                "term + app filter",
                try measure("alpha", SearchFilter(appBundleID: "com.apple.Safari"))
            ),
        ]
        for (name, seconds) in timings {
            #expect(seconds < 0.1, "\(name) took \(Int(seconds * 1000)) ms")
        }
    }
}

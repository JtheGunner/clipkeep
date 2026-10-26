import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct ContentStoreTests {
    private func makeStore() throws -> (ContentStore, Database, TemporaryDatabase) {
        let temp = try TemporaryDatabase()
        let database = try temp.open()
        return (ContentStore(database: database), database, temp)
    }

    @Test func sameTextIsStoredOnceWithTwoEvents() throws {
        let (store, database, temp) = try makeStore()
        defer { temp.remove() }

        let first = try store.record(text: "hello")
        let second = try store.record(text: "hello")

        #expect(first.isNewContent)
        #expect(!second.isNewContent)
        #expect(first.contentID == second.contentID)
        #expect(first.eventID != second.eventID)
        #expect(try store.occurrenceCount(contentID: first.contentID) == 2)
        let contents = try database.read {
            try $0.query("SELECT count(*) FROM contents") { $0.int(0) }
        }
        #expect(contents == [1])
    }

    @Test func differentTextCreatesSeparateContent() throws {
        let (store, _, temp) = try makeStore()
        defer { temp.remove() }

        let first = try store.record(text: "a")
        let second = try store.record(text: "A")

        #expect(first.contentID != second.contentID)
    }

    @Test func contextIsStoredPerEvent() throws {
        let (store, database, temp) = try makeStore()
        defer { temp.remove() }
        let context = CopyContext(
            appBundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Docs",
            url: "https://example.com")

        _ = try store.record(text: "x", context: context)

        let row = try database.read {
            try $0.query("SELECT app_bundle_id, app_name, window_title, url FROM copy_events") {
                [$0.text(0), $0.text(1), $0.text(2), $0.text(3)]
            }
        }
        #expect(row == [["com.apple.Safari", "Safari", "Docs", "https://example.com"]])
    }

    @Test func missingContextFieldsStayNull() throws {
        let (store, database, temp) = try makeStore()
        defer { temp.remove() }

        _ = try store.record(text: "x")

        let nulls = try database.read {
            try $0.query("SELECT window_title, url FROM copy_events") {
                [$0.isNull(0), $0.isNull(1)]
            }
        }
        #expect(nulls == [[true, true]])
    }

    @Test func deletingContentRemovesItsEvents() throws {
        let (store, database, temp) = try makeStore()
        defer { temp.remove() }
        let recorded = try store.record(text: "x")

        try database.write {
            try $0.execute("DELETE FROM contents WHERE id = ?", [.int(recorded.contentID)])
        }

        let events = try database.read {
            try $0.query("SELECT count(*) FROM copy_events") { $0.int(0) }
        }
        #expect(events == [0])
    }

    @Test func storesUnicodeAndMultilineText() throws {
        let (store, database, temp) = try makeStore()
        defer { temp.remove() }
        let text = "Grüezi 👋\nzweite Zeile\t\"quoted\""

        _ = try store.record(text: text)

        let stored = try database.read { try $0.query("SELECT text FROM contents") { $0.text(0) } }
        #expect(stored == [text])
    }
}

@Suite struct ContentStoreNulTests {
    @Test func textsDifferingAfterNulStayDistinct() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let store = ContentStore(database: try temp.open())

        let first = try store.record(text: "a\0b")
        let second = try store.record(text: "a\0c")

        #expect(first.contentID != second.contentID)
    }
}

@Suite struct ContentStoreAnalysisTests {
    @Test func newContentGetsItsKindAndEntities() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database)

        _ = try store.record(text: "https://github.com/groue/GRDB.swift")

        let kinds = try database.read { try $0.query("SELECT kind FROM contents") { $0.text(0) } }
        let entities = try database.read {
            try $0.query("SELECT kind, value FROM entities ORDER BY kind, value") {
                "\($0.text(0)):\($0.text(1))"
            }
        }
        #expect(kinds == ["url"])
        #expect(entities == ["domain:github.com", "repo:github.com/groue/grdb.swift"])
    }

    @Test func recopyingDoesNotDuplicateEntities() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database)

        _ = try store.record(text: "Fixes CLIPK-12")
        _ = try store.record(text: "Fixes CLIPK-12")

        let count = try database.read {
            try $0.query("SELECT count(*) FROM entities") { $0.int(0) }
        }
        #expect(count == [1])
    }
}

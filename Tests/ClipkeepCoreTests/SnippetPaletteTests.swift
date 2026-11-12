import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetPaletteTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .gmt
        return calendar
    }

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let store: SnippetStore
        let search: SnippetPaletteSearch

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = SnippetStore(database: database)
            search = SnippetPaletteSearch(store: store)
        }
    }

    private func snippet(
        id: Int64 = 3, text: String = "SELECT 1", language: SnippetLanguage = .sql,
        ago: TimeInterval = 10, count: Int = 1
    ) -> Snippet {
        Snippet(
            id: id, text: text, language: language, origin: .auto, appName: "Terminal",
            createdAt: now.addingTimeInterval(-ago - 100),
            lastCopiedAt: now.addingTimeInterval(-ago), copyCount: count)
    }

    // MARK: - Search

    @Test func emptyQueryListsNewestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "ls -la /tmp", language: .shell, origin: .auto, appName: nil,
            at: now.addingTimeInterval(-100))
        _ = try fixture.store.add(
            text: "SELECT 1 FROM dual", language: .sql, origin: .auto, appName: nil, at: now)

        for query in ["", "   "] {
            let rows = try fixture.search.rows(for: query, now: now)
            #expect(rows.map(\.text) == ["SELECT 1 FROM dual", "ls -la /tmp"])
        }
    }

    @Test func queryFiltersAndOrders() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "kubectl get pods", language: .shell, origin: .auto, appName: nil, at: now)
        _ = try fixture.store.add(
            text: "SELECT * FROM orders", language: .sql, origin: .auto, appName: nil,
            at: now.addingTimeInterval(-50))
        _ = try fixture.store.add(
            text: "SELECT id FROM orders WHERE total > 10", language: .sql, origin: .auto,
            appName: nil, at: now.addingTimeInterval(-40))
        // A second copy raises the count of the older query above the newer one.
        _ = try fixture.store.add(
            text: "SELECT * FROM orders", language: .sql, origin: .auto, appName: nil,
            at: now.addingTimeInterval(-30))

        let rows = try fixture.search.rows(for: "  orders ", now: now)

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.text.contains("orders") })
        #expect(rows.first?.text == "SELECT * FROM orders")
        #expect(try fixture.search.rows(for: "nothing-here", now: now).isEmpty)
    }

    @Test func theSearchStopsAtTheRowLimit() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for index in 0..<(PaletteSearch.rowLimit + 5) {
            _ = try fixture.store.add(
                text: "echo item\(index)", language: .shell, origin: .auto, appName: nil,
                at: now.addingTimeInterval(Double(-index)))
        }

        #expect(try fixture.search.rows(for: "", now: now).count == PaletteSearch.rowLimit)
        #expect(try fixture.search.rows(for: "echo", now: now).count == PaletteSearch.rowLimit)
    }

    @Test func zeroSnippetsGiveAnEmptyList() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }

        #expect(try fixture.search.rows(for: "", now: now).isEmpty)
        #expect(try fixture.search.rows(for: "select", now: now).isEmpty)
        #expect(try fixture.search.rows(for: "ls", now: now).isEmpty)
    }

    @Test func aDeletedSnippetLeavesTheList() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "ls -la", language: .shell, origin: .auto, appName: nil, at: now)
        let row = try #require(try fixture.search.rows(for: "", now: now).first)

        #expect(try fixture.store.delete(id: row.contentID))

        #expect(try fixture.search.rows(for: "", now: now).isEmpty)
    }

    @Test func historyPaletteSearchStillConformsAndIsUnchanged() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database)
        _ = try store.record(text: "older entry", copiedAt: now.addingTimeInterval(-100))
        _ = try store.record(text: "newer entry", copiedAt: now)
        let history = PaletteSearch(database: database)
        let source: any PaletteSource = history

        let throughProtocol = try source.rows(for: "entry", now: now)

        #expect(throughProtocol == (try history.rows(for: "entry", now: now)))
        #expect(throughProtocol.map(\.text) == ["newer entry", "older entry"])
        #expect(throughProtocol.first?.subtitle == "gerade eben · Text")
    }

    // MARK: - Rows

    @Test func rowShowsFirstLineAndLanguageAndCount() {
        let row = PaletteRow(
            snippet: snippet(text: "\n  SELECT 1  \nFROM dual", count: 2), now: now,
            calendar: calendar)

        #expect(row.contentID == 3)
        #expect(row.text == "\n  SELECT 1  \nFROM dual")
        #expect(row.title == "SELECT 1")
        #expect(row.subtitle.contains("SQL"))
        #expect(row.subtitle.contains("2×"))
        #expect(row.subtitle == "gerade eben · SQL · 2×")
    }

    @Test func aSingleCopyShowsNoCount() {
        let row = PaletteRow(snippet: snippet(ago: 300), now: now, calendar: calendar)
        #expect(row.subtitle == "vor 5 Min. · SQL")
    }

    @Test(arguments: [
        (SnippetLanguage.shell, "Shell", "terminal"),
        (SnippetLanguage.sql, "SQL", "chevron.left.forwardslash.chevron.right"),
        (SnippetLanguage.yaml, "YAML", "chevron.left.forwardslash.chevron.right"),
    ])
    func theLanguageNamesTheRowAndPicksTheIcon(
        language: SnippetLanguage, name: String, symbol: String
    ) {
        let row = PaletteRow(snippet: snippet(language: language), now: now, calendar: calendar)
        #expect(row.typeName == name)
        #expect(row.symbolName == symbol)
        #expect(row.subtitle == "gerade eben · \(name)")
    }

    @Test func olderSnippetsShowTheDate() {
        let row = PaletteRow(snippet: snippet(ago: 10 * 86_400), now: now, calendar: calendar)
        #expect(row.subtitle == "05.01.2027 · SQL")
    }

    @Test func longSnippetTitlesAreCut() {
        let row = PaletteRow(
            snippet: snippet(text: String(repeating: "x", count: 500)), now: now)
        #expect(row.title.count == PaletteRow.maximumTitleLength)
        #expect(row.title.hasSuffix("…"))
    }
}

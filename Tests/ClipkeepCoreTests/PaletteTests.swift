import AppKit
import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct PaletteTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .gmt
        return calendar
    }

    private func hit(
        text: String = "hello", kind: String = "text", ago: TimeInterval = 10, count: Int = 1,
        app: String? = "Safari"
    ) -> SearchHit {
        SearchHit(
            contentID: 7, text: text, kind: kind, lastCopiedAt: now.addingTimeInterval(-ago),
            occurrenceCount: count, lastAppName: app, lastWindowTitle: nil, lastURL: nil)
    }

    // MARK: - Rows

    @Test func theTitleIsTheFirstNonEmptyLine() {
        let row = PaletteRow(
            hit: hit(text: "\n  \n  first line  \nsecond"), now: now, calendar: calendar)
        #expect(row.title == "first line")
        #expect(row.text == "\n  \n  first line  \nsecond")
    }

    @Test func longTitlesAreCut() {
        let row = PaletteRow(hit: hit(text: String(repeating: "x", count: 500)), now: now)
        #expect(row.title.count == PaletteRow.maximumTitleLength)
        #expect(row.title.hasSuffix("…"))
    }

    @Test(arguments: [
        (10.0, "gerade eben"), (300.0, "vor 5 Min."), (7_300.0, "vor 2 Std."),
    ])
    func showsHowLongAgo(ago: Double, expected: String) {
        let row = PaletteRow(hit: hit(ago: ago), now: now, calendar: calendar)
        #expect(row.subtitle.contains(expected))
    }

    @Test func olderCopiesShowYesterdayOrTheDate() {
        let yesterday = PaletteRow(hit: hit(ago: 86_400), now: now, calendar: calendar)
        #expect(yesterday.subtitle.contains("gestern"))
        let old = PaletteRow(hit: hit(ago: 10 * 86_400), now: now, calendar: calendar)
        #expect(old.subtitle.contains("."))
        #expect(!old.subtitle.contains("gestern"))
    }

    @Test func theSubtitleHasAppTypeAndCount() {
        let row = PaletteRow(hit: hit(kind: "url", count: 3), now: now, calendar: calendar)
        #expect(row.subtitle == "Safari · gerade eben · Link · 3×")
        let noApp = PaletteRow(hit: hit(app: nil), now: now, calendar: calendar)
        #expect(noApp.subtitle == "gerade eben · Text")
    }

    // MARK: - Search

    @Test func theSearchHidesSecretPlaceholders() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database)
        _ = try store.record(text: "deploy token notes", copiedAt: now)
        _ = try store.record(text: "deploy token placeholder", copiedAt: now, kind: .secret)
        let rows = try PaletteSearch(database: database).rows(for: "deploy", now: now)
        #expect(rows.map(\.text) == ["deploy token notes"])
    }

    @Test func anEmptyQueryListsTheNewestFirst() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database)
        _ = try store.record(text: "older entry", copiedAt: now.addingTimeInterval(-100))
        _ = try store.record(text: "newer entry", copiedAt: now)
        let rows = try PaletteSearch(database: database).rows(for: "  ", now: now)
        #expect(rows.map(\.text) == ["newer entry", "older entry"])
    }

    // MARK: - Own copies

    @Test func theOwnCopyIsNotCapturedAgain() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("clipkeep-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let pipeline = CapturePipeline(store: ContentStore(database: database))

        #expect(OwnCopyWriter(pasteboard: board).copy("picked from the palette"))
        let snapshot = try #require(SystemPasteboard(pasteboard: board).snapshot())
        #expect(snapshot.types.contains(OwnCopyWriter.markerType))
        #expect(try pipeline.process(snapshot, source: CopyContext()) == .skipped(.ownCopy))
        let stored = try database.read {
            try $0.query("SELECT count(*) FROM contents") { $0.int(0) }.first ?? 0
        }
        #expect(stored == 0)
    }

    @Test func theOwnCopyReplacesWhatWasOnThePasteboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("clipkeep-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("before", forType: .string)
        OwnCopyWriter(pasteboard: board).copy("after")
        #expect(board.string(forType: .string) == "after")
    }

    @Test func aNormalCopyIsStillCaptured() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("clipkeep-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("from another app", forType: .string)
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let pipeline = CapturePipeline(store: ContentStore(database: try temp.open()))
        let snapshot = try #require(SystemPasteboard(pasteboard: board).snapshot())
        guard case .recorded = try pipeline.process(snapshot, source: CopyContext()) else {
            Issue.record("expected the copy to be recorded")
            return
        }
    }
}

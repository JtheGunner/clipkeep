import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct HistoryBrowserTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let store: ContentStore
        let browser: HistoryBrowser

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
            browser = HistoryBrowser(database: database)
        }
    }

    /// Records one copy per text, `minutes` apart, starting at `start`.
    @discardableResult
    private func copy(
        _ fixture: Fixture, _ texts: [String], start: Date, minutes: Double = 1,
        context: CopyContext = CopyContext()
    ) throws -> [RecordedCopy] {
        try texts.enumerated().map { index, text in
            try fixture.store.record(
                text: text, copiedAt: start.addingTimeInterval(Double(index) * minutes * 60),
                context: context)
        }
    }

    // MARK: - Day timeline

    private var zurich: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .gmt
        return calendar
    }

    private func summary(_ id: Int64, at start: Date) -> SessionSummary {
        SessionSummary(
            id: id, startedAt: start, endedAt: start.addingTimeInterval(60), eventCount: 1,
            start: .first, dominantApps: [], topEntities: [], topicID: nil)
    }

    @Test func theTimelineGroupsSessionsByDayAndExtendsTheLastSectionAcrossPages() {
        var timeline = DayTimeline(calendar: zurich)
        // 1_800_000_000 is 2027-01-15 09:00 in Zurich.
        let today = base
        timeline.append([summary(3, at: today), summary(2, at: today.addingTimeInterval(-3_600))])
        timeline.append([
            summary(1, at: today.addingTimeInterval(-7_200)),
            summary(0, at: today.addingTimeInterval(-86_400)),
        ])
        #expect(timeline.sections.count == 2)
        #expect(timeline.sections.map { $0.sessions.map(\.id) } == [[3, 2, 1], [0]])
        #expect(timeline.last?.id == 0)
        #expect(timeline.sessionCount == 4)
    }

    @Test func anEmptyTimelineHasNoCursor() {
        let timeline = DayTimeline(calendar: zurich)
        #expect(timeline.last == nil)
        #expect(timeline.sections.isEmpty)
    }

    // MARK: - Sessions

    @Test func sessionPagesFollowEachOtherWithoutGapsOrRepeats() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for index in 0..<7 {
            try copy(
                fixture, ["session \(index) text"],
                start: base.addingTimeInterval(Double(index) * 7_200))
        }
        var seen: [Int64] = []
        var cursor: SessionSummary?
        while true {
            let page = try fixture.browser.sessions(limit: 3, after: cursor)
            if page.isEmpty { break }
            seen += page.map(\.id)
            cursor = page.last
        }
        #expect(seen.count == 7)
        #expect(Set(seen).count == 7)
        let startTimes = try fixture.browser.sessions(limit: 10).map(\.startedAt)
        #expect(startTimes == startTimes.sorted(by: >))
    }

    @Test func aSessionOpensWithItsEntriesInOrderOfCopying() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, ["first thing", "second thing", "third thing"], start: base)
        let session = try #require(try fixture.browser.sessions().first)
        #expect(session.eventCount == 3)
        let entries = try fixture.browser.entries(inSession: session.id)
        #expect(entries.map(\.preview) == ["first thing", "second thing", "third thing"])
    }

    @Test func entryPagesFollowACursor() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, (0..<5).map { "entry number \($0)" }, start: base)
        let session = try #require(try fixture.browser.sessions().first)
        let first = try fixture.browser.entries(inSession: session.id, limit: 2)
        let second = try fixture.browser.entries(inSession: session.id, limit: 2, after: first.last)
        let third = try fixture.browser.entries(inSession: session.id, limit: 2, after: second.last)
        #expect((first + second + third).map(\.preview) == (0..<5).map { "entry number \($0)" })
        #expect(third.count == 1)
        #expect(try fixture.browser.entries(inSession: session.id, limit: 0).isEmpty)
    }

    @Test func entriesCarryTheirContextAndFlags() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copied = try copy(
            fixture, ["note for later"], start: base,
            context: CopyContext(
                appBundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Docs",
                url: "https://example.com/a"))
        try ItemActions(database: fixture.database).setPinned(
            true, contentID: copied[0].contentID)
        let session = try #require(try fixture.browser.sessions().first)
        let entry = try #require(try fixture.browser.entries(inSession: session.id).first)
        #expect(entry.appName == "Safari")
        #expect(entry.windowTitle == "Docs")
        #expect(entry.url == "https://example.com/a")
        #expect(entry.isPinned)
        #expect(!entry.isStarred)
    }

    @Test func deletedItemsDisappearFromTheEntryList() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copied = try copy(fixture, ["keep this one", "drop this one"], start: base)
        try ItemActions(database: fixture.database).delete(contentID: copied[1].contentID)
        let session = try #require(try fixture.browser.sessions().first)
        #expect(
            try fixture.browser.entries(inSession: session.id).map(\.preview) == ["keep this one"])
    }

    @Test func longTextsAreCutInTheListButComeWholeInTheDetail() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let long = String(repeating: "word ", count: 1_000)
        let copied = try copy(fixture, [long], start: base)
        let session = try #require(try fixture.browser.sessions().first)
        let entry = try #require(try fixture.browser.entries(inSession: session.id).first)
        #expect(entry.preview.count == HistoryBrowser.previewLength)
        let detail = try #require(try fixture.browser.detail(contentID: copied[0].contentID))
        #expect(detail.text == long)
    }

    // MARK: - Detail

    @Test func theDetailListsOccurrencesEntitiesAndTheScore() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let text = "see https://github.com/acme/api/issues/1"
        let first = try fixture.store.record(
            text: text, copiedAt: base,
            context: CopyContext(appName: "Safari", windowTitle: "Issue"))
        _ = try fixture.store.record(
            text: text, copiedAt: base.addingTimeInterval(3 * 3_600),
            context: CopyContext(appName: "Xcode"))
        let detail = try #require(
            try fixture.browser.detail(
                contentID: first.contentID, now: base.addingTimeInterval(4 * 3_600)))
        #expect(detail.occurrenceCount == 2)
        #expect(detail.occurrences.map(\.appName) == ["Xcode", "Safari"])
        #expect(detail.occurrences.allSatisfy { $0.sessionID != nil })
        #expect(detail.entities.contains { $0.kind == "repo" && $0.value == "github.com/acme/api" })
        #expect(detail.score != nil)
        #expect(detail.kind == "url" || detail.kind == "text")
    }

    @Test func theDetailOfADeletedOrUnknownItemIsNil() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copied = try copy(fixture, ["gone soon"], start: base)
        #expect(try fixture.browser.detail(contentID: 9_999) == nil)
        try ItemActions(database: fixture.database).delete(contentID: copied[0].contentID)
        #expect(try fixture.browser.detail(contentID: copied[0].contentID) == nil)
    }

    @Test func occurrencesAreLimited() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        var last: RecordedCopy?
        for index in 0..<(HistoryBrowser.occurrenceLimit + 5) {
            last = try fixture.store.record(
                text: "same text again", copiedAt: base.addingTimeInterval(Double(index)))
        }
        let lastID = try #require(last).contentID
        let detail = try #require(try fixture.browser.detail(contentID: lastID))
        #expect(detail.occurrences.count == HistoryBrowser.occurrenceLimit)
        #expect(detail.occurrenceCount == HistoryBrowser.occurrenceLimit + 5)
    }

    // MARK: - Entities and topics

    private let repoA = "see https://github.com/acme/api/issues/1 "
    private let repoB = "see https://github.com/acme/web/issues/2 "

    @Test func entityChoicesCountItemsAndSkipSecretsAndDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copied = try copy(
            fixture, [repoA + "one", repoA + "two", repoB + "three"], start: base)
        try ItemActions(database: fixture.database).delete(contentID: copied[1].contentID)
        let choices = try fixture.browser.entityChoices()
        let api = choices.first {
            $0.filter == EntityFilter(kind: "repo", value: "github.com/acme/api")
        }
        #expect(api?.uses == 1)
        #expect(
            choices.contains {
                $0.filter == EntityFilter(kind: "repo", value: "github.com/acme/web")
            })
        #expect(try fixture.browser.entityChoices(limit: 0).isEmpty)
    }

    @Test func theEntityFilterKeepsOnlySessionsWithThatEntity() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, [repoA + "alpha text"], start: base)
        try copy(fixture, [repoB + "bravo text"], start: base.addingTimeInterval(4 * 3_600))
        try copy(fixture, ["no entities here"], start: base.addingTimeInterval(8 * 3_600))
        let filter = EntityFilter(kind: "repo", value: "github.com/acme/api")
        let sessions = try fixture.browser.sessions(entity: filter)
        #expect(sessions.count == 1)
        let entries = try fixture.browser.entries(inSession: sessions[0].id)
        #expect(entries.map(\.preview) == [repoA + "alpha text"])
        #expect(try fixture.browser.sessions(limit: 1, after: sessions[0], entity: filter).isEmpty)
    }

    private func clusteredTopics(_ fixture: Fixture) throws -> [TopicSummary] {
        try copy(
            fixture, ["https://docs.swift.org/actors swift actor isolation"], start: base)
        try copy(
            fixture, ["https://kubernetes.io/ingress kubernetes ingress controller"],
            start: base.addingTimeInterval(4 * 3_600))
        try TopicService(database: fixture.database).cluster(
            now: base.addingTimeInterval(30 * 86_400))
        return try fixture.browser.topics()
    }

    @Test func topicsFilterByEntityAndListTheirSessions() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let all = try clusteredTopics(fixture)
        #expect(all.count == 2)
        let swift = EntityFilter(kind: "domain", value: "docs.swift.org")
        let filtered = try fixture.browser.topics(entity: swift)
        #expect(filtered.count == 1)
        let sessions = try fixture.browser.sessions(inTopic: filtered[0].id)
        #expect(sessions.count == 1)
        #expect(sessions[0].topicID == filtered[0].id)
        #expect(try fixture.browser.sessions(inTopic: filtered[0].id, entity: swift).count == 1)
        let other = EntityFilter(kind: "domain", value: "kubernetes.io")
        #expect(try fixture.browser.sessions(inTopic: filtered[0].id, entity: other).isEmpty)
        #expect(
            try fixture.browser.topics(entity: EntityFilter(kind: "repo", value: "none")).isEmpty)
    }

    @Test func aSessionKnowsItsTopicAndWhy() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let topics = try clusteredTopics(fixture)
        let session = try #require(try fixture.browser.sessions(inTopic: topics[0].id).first)
        let info = try #require(try fixture.browser.topicInfo(ofSession: session.id))
        #expect(info.topicID == topics[0].id)
        #expect(info.label == topics[0].label)
        #expect(!info.reason.isEmpty)
        #expect(!info.isLocked)
        #expect(try fixture.browser.topicInfo(ofSession: 9_999) == nil)
    }

    @Test func searchCanBeScopedToATopic() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let topics = try clusteredTopics(fixture)
        let search = SearchService(database: fixture.database)
        let inFirst = try search.search("https", filter: SearchFilter(topicID: topics[0].id))
        let inSecond = try search.search("https", filter: SearchFilter(topicID: topics[1].id))
        #expect(inFirst.count == 1)
        #expect(inSecond.count == 1)
        #expect(inFirst[0].contentID != inSecond[0].contentID)
        #expect(try search.search("https", filter: SearchFilter(topicID: 9_999)).isEmpty)
    }

    @Test func searchCanBeScopedToASessionAndADay() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, ["shared word monday"], start: base)
        try copy(fixture, ["shared word tuesday"], start: base.addingTimeInterval(86_400))
        let sessions = try fixture.browser.sessions()
        let search = SearchService(database: fixture.database)
        let inSession = try search.search("shared", filter: SearchFilter(sessionID: sessions[1].id))
        #expect(inSession.map(\.text) == ["shared word monday"])
        let day = try search.search(
            "shared",
            filter: SearchFilter(
                copiedAfter: base.addingTimeInterval(86_000),
                copiedBefore: base.addingTimeInterval(90_000)))
        #expect(day.map(\.text) == ["shared word tuesday"])
    }

    @Test func deletedItemsDoNotMatchAnEntityFilter() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copied = try copy(fixture, [repoA + "only match"], start: base)
        let filter = EntityFilter(kind: "repo", value: "github.com/acme/api")
        #expect(try fixture.browser.sessions(entity: filter).count == 1)
        try ItemActions(database: fixture.database).delete(contentID: copied[0].contentID)
        #expect(try fixture.browser.sessions(entity: filter).isEmpty)
    }

    @Test func sessionsByIDKeepOrderAcrossChunks() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let count = 1_200
        try fixture.database.write { connection in
            for index in 0..<count {
                try connection.execute(
                    "INSERT INTO sessions (started_at, ended_at, event_count) VALUES (?, ?, 1)",
                    [.double(Double(index)), .double(Double(index))])
            }
        }
        let service = SessionService(database: fixture.database)
        let all = try service.sessions(ids: (1...Int64(count)).map { $0 } + [99_999])
        #expect(all.count == count)
        #expect(all.map(\.startedAt) == all.map(\.startedAt).sorted(by: >))
    }

    @Test func aRowKeepsItsPlaceWhenPinnedOrStarred() {
        let hit = SearchHit(
            contentID: 1, text: "note", kind: "text", lastCopiedAt: base, occurrenceCount: 1,
            lastAppName: nil, lastWindowTitle: nil, lastURL: nil)
        let row = HistoryRow(hit: hit, format: HistoryFormat(now: base, calendar: zurich))
        let pinned = row.with(isPinned: true, isStarred: false)
        #expect(pinned.subtitle.hasSuffix("Text · angeheftet"))
        #expect(pinned.with(isPinned: false, isStarred: false) == row)
    }

    // MARK: - Formatting

    @Test func daysAreNamedRelativeToToday() {
        let format = HistoryFormat(now: base, calendar: zurich)
        #expect(format.dayTitle(base) == "Heute")
        #expect(format.dayTitle(base.addingTimeInterval(-86_400)) == "Gestern")
        #expect(format.dayTitle(base.addingTimeInterval(-5 * 86_400)).hasSuffix("10.01.2027"))
    }

    @Test func aSessionRowShowsTimesCountAndApps() {
        let format = HistoryFormat(now: base, calendar: zurich)
        let session = SessionSummary(
            id: 1, startedAt: base, endedAt: base.addingTimeInterval(47 * 60), eventCount: 12,
            start: .first,
            dominantApps: [.init(bundleID: "com.apple.Safari", count: 8)],
            topEntities: [.init(kind: "repo", value: "github.com/acme/api", count: 3)], topicID: nil
        )
        #expect(format.sessionTitle(session) == "09:00–09:47 · 12 Einträge")
        #expect(format.sessionSubtitle(session) == "Safari · github.com/acme/api")
    }

    @Test func scoreLinesNameTheContributingSignalsAndTheTotal() {
        let score = ScoreExplanation(
            components: [
                ScoreComponent(name: "frecency", value: 1.5, detail: ""),
                ScoreComponent(name: "star", value: 0, detail: ""),
            ], total: 1.5, importance: 0.4, tier: .hot)
        let lines = HistoryFormat(now: base, calendar: zurich).scoreLines(score)
        #expect(
            lines == [
                "Aktualität und Häufigkeit: +1.50", "Summe: +1.50 → Wichtigkeit 40 %",
                "Ablage: aktuell",
            ])
    }

    @Test func aDayScopeCoversExactlyThatCalendarDay() {
        let filter = HistoryScope.day(base).filter(limit: 10, calendar: zurich)
        // 1_800_000_000 is 2027-01-15 09:00 in Zurich.
        #expect(filter.copiedAfter == base.addingTimeInterval(-9 * 3_600))
        #expect(filter.copiedBefore == base.addingTimeInterval(15 * 3_600))
        #expect(filter.limit == 10)
    }

    @Test func otherScopesSetOneField() {
        #expect(HistoryScope.all.filter(limit: 5) == SearchFilter(limit: 5))
        #expect(HistoryScope.session(4).filter(limit: 5).sessionID == 4)
        #expect(HistoryScope.topic(6).filter(limit: 5).topicID == 6)
    }

    @Test func rowsFromEntriesAndHitsShowFlagsAppAndType() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copied = try copy(
            fixture, ["pinned note text"], start: base,
            context: CopyContext(appName: "Notes"))
        try ItemActions(database: fixture.database).setPinned(true, contentID: copied[0].contentID)
        try ItemActions(database: fixture.database).setStarred(true, contentID: copied[0].contentID)
        let format = HistoryFormat(now: base, calendar: zurich)

        let session = try #require(try fixture.browser.sessions().first)
        let entry = try #require(try fixture.browser.entries(inSession: session.id).first)
        let fromEntry = HistoryRow(entry: entry, format: format)
        let hit = try #require(try SearchService(database: fixture.database).search("pinned").first)
        let fromHit = HistoryRow(hit: hit, format: format)

        #expect(fromEntry == fromHit)
        #expect(fromEntry.title == "pinned note text")
        #expect(fromEntry.subtitle == "15.01.2027 09:00 · Notes · Text · angeheftet · markiert")
        #expect(fromHit.isPinned && fromHit.isStarred)
    }

    // MARK: - Scale

    @Test func aHundredThousandEntriesStayFast() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let sessionCount = 2_000
        let perSession = 50
        try fixture.database.write { connection in
            for session in 0..<sessionCount {
                let start = Double(session) * 7_200
                try connection.execute(
                    """
                    INSERT INTO sessions (started_at, ended_at, event_count, first_event_id)
                    VALUES (?, ?, ?, ?)
                    """,
                    [
                        .double(start), .double(start + 3_000), .int(Int64(perSession)),
                        .int(Int64(session * perSession + 1)),
                    ])
                let sessionID = connection.lastInsertRowID
                for offset in 0..<perSession {
                    let index = session * perSession + offset
                    try connection.execute(
                        """
                        INSERT INTO contents
                            (hash, normalized_hash, text, search_text, first_seen_at, last_copied_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text("h\(index)"), .text("n\(index)"), .text("item \(index)"),
                            .text("item \(index)"), .double(start), .double(start),
                        ])
                    try connection.execute(
                        """
                        INSERT INTO copy_events (content_id, copied_at, session_id)
                        VALUES (?, ?, ?)
                        """,
                        [
                            .int(connection.lastInsertRowID), .double(start + Double(offset)),
                            .int(sessionID),
                        ])
                }
            }
        }

        func best(_ work: () throws -> Void) throws -> Double {
            try (0..<3).map { _ in
                let started = Date()
                try work()
                return Date().timeIntervalSince(started)
            }.min() ?? .infinity
        }
        let firstPage = try fixture.browser.sessions(limit: 50)
        #expect(firstPage.count == 50)
        let timings: [(String, Double)] = [
            ("first session page", try best { _ = try fixture.browser.sessions(limit: 50) }),
            (
                "session page far back",
                try best {
                    let oldest = SessionSummary(
                        id: 10, startedAt: Date(timeIntervalSince1970: 7_200 * 10), endedAt: Date(),
                        eventCount: 1, start: .first, dominantApps: [], topEntities: [],
                        topicID: nil)
                    _ = try fixture.browser.sessions(limit: 50, after: oldest)
                }
            ),
            (
                "listing of an old day",
                try best {
                    let day = Date(timeIntervalSince1970: 7_200 * 10)
                    _ = try SearchService(database: fixture.database).search(
                        "", filter: HistoryScope.day(day).filter(limit: 200))
                }
            ),
            (
                "entries of a session",
                try best { _ = try fixture.browser.entries(inSession: firstPage[0].id, limit: 100) }
            ),
        ]
        for (name, seconds) in timings {
            #expect(
                !PerformanceBudget.isEnforced || seconds < 0.1,
                "\(name) took \(Int(seconds * 1000)) ms")
        }
    }
}

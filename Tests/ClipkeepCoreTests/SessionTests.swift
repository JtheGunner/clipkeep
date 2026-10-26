import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SessionSegmenterTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ id: Int64, minute: Double, app: String? = nil, context: String? = nil
    ) -> SessionEvent {
        SessionEvent(
            id: id, time: base.addingTimeInterval(minute * 60), appBundleID: app, context: context)
    }

    @Test func noEventsGiveNoSessions() {
        #expect(SessionSegmenter.segment([]).isEmpty)
    }

    @Test func oneEventIsOneSessionStartingFirst() {
        let drafts = SessionSegmenter.segment([event(1, minute: 0)])
        #expect(drafts.count == 1)
        #expect(drafts[0].start == .first)
        #expect(drafts[0].firstEventID == 1)
    }

    @Test func aGapJustOverTheThresholdSplitsAndExactlyTheThresholdDoesNot() {
        let exact = SessionSegmenter.segment([event(1, minute: 0), event(2, minute: 25)])
        #expect(exact.count == 1)
        let over = SessionSegmenter.segment([event(1, minute: 0), event(2, minute: 25.5)])
        #expect(over.count == 2)
        #expect(over[1].start == .gap(minutes: 25))
    }

    @Test func thresholdIsConfigurable() {
        let configuration = SessionConfiguration(gapMinutes: 5)
        let drafts = SessionSegmenter.segment(
            [event(1, minute: 0), event(2, minute: 4), event(3, minute: 10)],
            configuration: configuration)
        #expect(drafts.map { $0.events.map(\.id) } == [[1, 2], [3]])
    }

    @Test func unsortedInputIsOrderedByTimeThenID() {
        let drafts = SessionSegmenter.segment([
            event(3, minute: 2), event(1, minute: 0), event(2, minute: 0),
        ])
        #expect(drafts.count == 1)
        #expect(drafts[0].events.map(\.id) == [1, 2, 3])
    }

    @Test func appSwitchOnlySSplitsAfterALongEnoughPause() {
        let quick = SessionSegmenter.segment([
            event(1, minute: 0, app: "a"), event(2, minute: 1, app: "b"),
        ])
        #expect(quick.count == 1)
        let paused = SessionSegmenter.segment([
            event(1, minute: 0, app: "a"), event(2, minute: 12, app: "b"),
        ])
        #expect(paused.count == 2)
        #expect(paused[1].start == .appSwitch(from: "a", to: "b", minutes: 12))
    }

    @Test func unknownAppsNeverTriggerAnAppSwitch() {
        let drafts = SessionSegmenter.segment([
            event(1, minute: 0, app: "a"), event(2, minute: 12), event(3, minute: 24, app: "a"),
        ])
        #expect(drafts.count == 1)
    }

    @Test func confirmedContextSwitchSplitsAtTheFirstNewEvent() {
        let drafts = SessionSegmenter.segment([
            event(1, minute: 0, context: "org/api"), event(2, minute: 1, context: "org/api"),
            event(3, minute: 2, context: "org/web"), event(4, minute: 3, context: "org/web"),
        ])
        #expect(drafts.map { $0.events.map(\.id) } == [[1, 2], [3, 4]])
        #expect(drafts[1].start == .contextSwitch(from: "org/api", to: "org/web"))
    }

    @Test func aSingleStrayContextDoesNotSplit() {
        let drafts = SessionSegmenter.segment([
            event(1, minute: 0, context: "org/api"), event(2, minute: 1, context: "other.com"),
            event(3, minute: 2, context: "org/api"), event(4, minute: 3, context: "org/api"),
        ])
        #expect(drafts.count == 1)
    }

    @Test func contextSwitchAtTheEndWithoutConfirmationDoesNotSplit() {
        let drafts = SessionSegmenter.segment([
            event(1, minute: 0, context: "org/api"), event(2, minute: 1, context: "org/web"),
        ])
        #expect(drafts.count == 1)
    }

    @Test func missingContextNeverSplitsAndAdoptsTheFirstKnownOne() {
        let drafts = SessionSegmenter.segment([
            event(1, minute: 0), event(2, minute: 1, context: "org/api"),
            event(3, minute: 2), event(4, minute: 3, context: "org/api"),
        ])
        #expect(drafts.count == 1)
    }

    @Test func confirmationCanBeRaised() {
        let configuration = SessionConfiguration(contextConfirmations: 3)
        let events = [
            event(1, minute: 0, context: "a"), event(2, minute: 1, context: "b"),
            event(3, minute: 2, context: "b"), event(4, minute: 3, context: "a"),
        ]
        #expect(SessionSegmenter.segment(events, configuration: configuration).count == 1)
    }

    @Test func everyEventLandsInExactlyOneSession() {
        var events: [SessionEvent] = []
        for index in 0..<200 {
            events.append(
                event(
                    Int64(index), minute: Double(index * 7),
                    app: index % 3 == 0 ? "a" : "b", context: index % 5 < 2 ? "x" : "y"))
        }
        let drafts = SessionSegmenter.segment(events)
        #expect(drafts.flatMap(\.events).map(\.id) == events.map(\.id))
        #expect(drafts.allSatisfy { !$0.events.isEmpty })
        #expect(SessionSegmenter.segment(events) == drafts)
    }

    @Test func explanationsAreReadableAndRoundTrip() {
        let starts: [SessionStart] = [
            .first, .gap(minutes: 40), .appSwitch(from: "a", to: "b", minutes: 12),
            .contextSwitch(from: "x", to: "y"),
        ]
        for start in starts {
            #expect(!start.explanation.isEmpty)
            #expect(SessionStart(code: start.code, detail: start.detail) == start)
        }
        #expect(SessionStart(code: "bogus", detail: "") == nil)
    }
}

@Suite struct SessionServiceTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let store: ContentStore
        let service: SessionService
        let database: Database
        let temp: TemporaryDatabase

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
            service = SessionService(database: database)
        }
    }

    private func at(_ minute: Double) -> Date { base.addingTimeInterval(minute * 60) }

    @discardableResult
    private func copy(
        _ fixture: Fixture, _ text: String, minute: Double, app: String? = "com.apple.Terminal",
        url: String? = nil
    ) throws -> RecordedCopy {
        try fixture.store.record(
            text: text, copiedAt: at(minute), context: CopyContext(appBundleID: app, url: url))
    }

    @Test func incrementalAssignmentCutsOnGaps() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "first copy", minute: 0)
        try copy(fixture, "second copy", minute: 5)
        try copy(fixture, "after a long break", minute: 60)

        let sessions = try fixture.service.sessions()
        #expect(sessions.count == 2)
        #expect(sessions[0].eventCount == 1)
        #expect(sessions[0].start == .gap(minutes: 55))
        #expect(sessions[1].eventCount == 2)
        #expect(sessions[1].start == .first)
        #expect(sessions[0].explanation.contains("55"))
        let unassigned = try fixture.database.read {
            try $0.query("SELECT count(*) FROM copy_events WHERE session_id IS NULL") { $0.int(0) }
        }
        #expect(unassigned == [0])
    }

    @Test func rebuildIsIdempotentAndKeepsIdsAndTopics() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for (index, minute) in [0.0, 3, 90, 95, 200].enumerated() {
            try copy(fixture, "copy number \(index)", minute: minute)
        }
        let before = try fixture.service.sessions()
        try fixture.database.write { connection in
            try connection.execute("INSERT INTO topics (label, created_at) VALUES ('t', 0)")
            try connection.execute(
                "UPDATE sessions SET topic_id = ?", [.int(connection.lastInsertRowID)])
        }
        #expect(try fixture.service.rebuild() == 3)
        #expect(try fixture.service.rebuild() == 3)
        let after = try fixture.service.sessions()
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.eventCount) == before.map(\.eventCount))
        #expect(after.allSatisfy { $0.topicID != nil })
    }

    @Test func rebuildMatchesIncrementalAssignment() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let apps = ["com.apple.Terminal", "com.apple.Safari", "com.apple.Terminal"]
        for index in 0..<60 {
            try copy(
                fixture, "snippet \(index)", minute: Double(index * 9), app: apps[index % 3])
        }
        func shape() throws -> [[String]] {
            try fixture.service.sessions(limit: 100).map {
                [String($0.eventCount), $0.start.code, $0.start.detail]
            }
        }
        let incremental = try shape()
        try fixture.service.rebuild()
        #expect(try shape() == incremental)
    }

    @Test func lateArrivingEventIsPlacedByTimeWithAFullRebuild() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "newer one", minute: 100)
        try copy(fixture, "newer two", minute: 101)
        try copy(fixture, "imported older", minute: 0)
        let sessions = try fixture.service.sessions()
        #expect(sessions.count == 2)
        #expect(sessions.map(\.eventCount) == [2, 1])
    }

    @Test func contextSwitchByRepoIsExplained() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "see https://github.com/acme/api/issues/1", minute: 0)
        try copy(fixture, "also https://github.com/acme/api/pull/2", minute: 1)
        try copy(fixture, "now https://github.com/acme/web/issues/3", minute: 2)
        try copy(fixture, "and https://github.com/acme/web/pull/4", minute: 3)
        let sessions = try fixture.service.sessions()
        #expect(sessions.count == 2)
        #expect(
            sessions[0].start
                == .contextSwitch(from: "github.com/acme/api", to: "github.com/acme/web"))
        #expect(sessions[0].explanation.contains("github.com/acme/web"))
    }

    @Test func metadataListsDominantAppsAndEntities() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "git status", minute: 0, app: "com.apple.Terminal")
        try copy(
            fixture, "git log https://github.com/acme/api", minute: 1, app: "com.apple.Terminal")
        try copy(
            fixture, "docs https://github.com/acme/api/wiki", minute: 2, app: "com.apple.Safari")
        let session = try #require(try fixture.service.sessions().first)
        #expect(session.dominantApps.first == .init(bundleID: "com.apple.Terminal", count: 2))
        #expect(session.dominantApps.count == 2)
        #expect(
            session.topEntities.contains(
                .init(kind: "repo", value: "github.com/acme/api", count: 2)))
    }

    @Test func deletedItemsDoNotAppearInSessionMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let secretish = try copy(fixture, "visit https://private.example.org/x", minute: 0)
        try copy(fixture, "plain text", minute: 1)
        try ItemActions(database: fixture.database).delete(contentID: secretish.contentID)
        try fixture.service.rebuild()
        let session = try #require(try fixture.service.sessions().first)
        #expect(session.topEntities.allSatisfy { $0.value != "private.example.org" })
        #expect(session.eventCount == 2)
    }

    @Test func browserHostIsUsedAsContextWhenThereIsNoRepo() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "a", minute: 0, url: "https://www.a.example/page")
        try copy(fixture, "b", minute: 1, url: "https://a.example/other")
        try copy(fixture, "c", minute: 2, url: "https://b.example/page")
        try copy(fixture, "d", minute: 3, url: "https://b.example/next")
        let sessions = try fixture.service.sessions()
        #expect(sessions.count == 2)
        #expect(sessions[0].start == .contextSwitch(from: "a.example", to: "b.example"))
    }

    @Test func bulkModeSkipsAssignmentUntilRebuild() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database, sessions: nil)
        _ = try store.record(text: "bulk one", copiedAt: at(0))
        _ = try store.record(text: "bulk two", copiedAt: at(100))
        let service = SessionService(database: database)
        #expect(try service.sessions().isEmpty)
        #expect(try service.rebuild() == 2)
    }

    @Test func listingPagesBackwardsAndHandlesLimits() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for index in 0..<4 { try copy(fixture, "page \(index)", minute: Double(index * 100)) }
        let all = try fixture.service.sessions(limit: 10)
        #expect(all.count == 4)
        #expect(try fixture.service.sessions(limit: 0).isEmpty)
        let older = try fixture.service.sessions(limit: 10, before: all[1].startedAt)
        #expect(older.map(\.id) == Array(all.dropFirst(2)).map(\.id))
    }

    @Test func searchFiltersBySessionAfterAssignment() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "morning note", minute: 0)
        try copy(fixture, "evening note", minute: 600)
        let evening = try #require(try fixture.service.sessions().first)
        let hits = try SearchService(database: fixture.database)
            .search("note", filter: SearchFilter(sessionID: evening.id))
        #expect(hits.map(\.text) == ["evening note"])
    }
}

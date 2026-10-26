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

    @Test func appSwitchOnlySplitsAfterALongEnoughPause() {
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
                fixture, "snippet \(index)", minute: Double(index * 13), app: apps[index % 3])
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
        // Only live items count, and the deleted host neither appears in the entities nor in a cut.
        #expect(session.eventCount == 1)
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
        let older = try fixture.service.sessions(limit: 10, after: all[1])
        #expect(older.map(\.id) == Array(all.dropFirst(2)).map(\.id))
        let firstPage = try fixture.service.sessions(limit: 2)
        #expect(
            try fixture.service.sessions(limit: 2, after: firstPage[1]).map(\.id)
                == all.dropFirst(2).map(\.id))
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

    private func shape(_ service: SessionService) throws -> [[String]] {
        try service.sessions(limit: 1_000).map {
            [String($0.eventCount), $0.start.code, $0.start.detail]
        }
    }

    @Test func laterCopiesKeepTheStartReasonOfTheTailSession() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "zero", minute: 0)
        try copy(fixture, "sixty", minute: 60)
        try copy(fixture, "sixty one", minute: 61)
        let incremental = try shape(fixture.service)
        #expect(incremental == [["2", "gap", "60"], ["1", "first", ""]])
        try fixture.service.rebuild()
        #expect(try shape(fixture.service) == incremental)
    }

    @Test func incrementalEqualsRebuildOnAMixedStream() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let apps = ["com.apple.Terminal", "com.apple.Safari", "com.apple.Notes"]
        let repos = [
            "https://github.com/acme/api/issues/", "https://github.com/acme/web/issues/",
            "plain text ",
        ]
        var minute = 0.0
        for index in 0..<120 {
            minute += [1.0, 2, 3, 12, 30, 1, 1][index % 7]
            try copy(
                fixture, "\(repos[(index / 6) % 3])\(index)", minute: minute, app: apps[index % 3])
        }
        let incremental = try shape(fixture.service)
        #expect(incremental.count > 5)
        try fixture.service.rebuild()
        #expect(try shape(fixture.service) == incremental)
        #expect(incremental.compactMap { Int($0[0]) }.reduce(0, +) == 120)
    }

    @Test func lateEventInsideTheTailMatchesARebuild() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let api = "https://github.com/acme/api/issues/"
        let web = "https://github.com/acme/web/issues/"
        try copy(fixture, api + "1", minute: 0)
        try copy(fixture, api + "2", minute: 1)
        try copy(fixture, web + "3", minute: 2)
        try copy(fixture, web + "4", minute: 4)
        try copy(fixture, api + "5", minute: 3)
        let incremental = try shape(fixture.service)
        try fixture.service.rebuild()
        #expect(try shape(fixture.service) == incremental)
        #expect(incremental.count == 1)
    }

    @Test func equalTimestampsAreOrderedByEventID() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for index in 0..<4 { try copy(fixture, "same time \(index)", minute: 5) }
        try copy(fixture, "later", minute: 60)
        let incremental = try shape(fixture.service)
        try fixture.service.rebuild()
        #expect(try shape(fixture.service) == incremental)
        #expect(incremental.map { $0[0] } == ["1", "4"])
    }

    @Test func purgingEventsLeavesNoGhostSessions() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "a one", minute: 0)
        try copy(fixture, "a two", minute: 1)
        let b1 = try copy(fixture, "b one", minute: 60)
        try copy(fixture, "b two", minute: 61)
        let actions = ItemActions(database: fixture.database)
        try actions.delete(contentID: b1.contentID, now: at(100))
        try actions.purgeDeleted(olderThanDays: 0, now: at(100))
        try copy(fixture, "c", minute: 64)

        let sessions = try fixture.service.sessions()
        let stored = try fixture.database.read { connection in
            try connection.query(
                "SELECT s.event_count, (SELECT count(*) FROM copy_events WHERE session_id = s.id) FROM sessions s"
            ) { ($0.int(0), $0.int(1)) }
        }
        #expect(sessions.count == 2)
        #expect(stored.allSatisfy { $0.0 == $0.1 && $0.1 > 0 })
    }

    @Test func retentionAlsoRepairsSessions() throws {
        let configuration = RankingConfiguration(policy: TierPolicy(archiveRetentionDays: 100))
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database, ranking: configuration)
        let old = at(-200 * 24 * 60)
        _ = try store.record(text: "ancient one", copiedAt: old)
        _ = try store.record(text: "recent one", copiedAt: at(0))
        let ranking = RankingService(database: database, configuration: configuration)
        #expect(try ranking.applyRetention(now: at(10)) == 1)
        let service = SessionService(database: database)
        #expect(try service.sessions().map(\.eventCount) == [1])
    }

    @Test func deletedHostsNeitherCutNorExplainSessions() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "x", minute: 0, url: "https://a.example/p")
        try copy(fixture, "y", minute: 1, url: "https://a.example/q")
        let p1 = try copy(fixture, "z", minute: 2, url: "https://private.example.org/1")
        let p2 = try copy(fixture, "w", minute: 3, url: "https://private.example.org/2")
        #expect(try fixture.service.sessions().count == 2)
        let actions = ItemActions(database: fixture.database)
        try actions.delete(contentID: p1.contentID)
        try actions.delete(contentID: p2.contentID)
        try fixture.service.rebuild()
        let sessions = try fixture.service.sessions()
        #expect(sessions.count == 1)
        #expect(sessions.allSatisfy { !$0.explanation.contains("private.example.org") })
    }

    @Test func deleteAndRestoreRefreshSessionMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "keep https://github.com/acme/api", minute: 0)
        let removed = try copy(fixture, "drop https://github.com/acme/web", minute: 1)
        let actions = ItemActions(database: fixture.database)
        try actions.delete(contentID: removed.contentID)
        var session = try #require(try fixture.service.sessions().first)
        #expect(session.eventCount == 1)
        #expect(session.topEntities.allSatisfy { $0.value != "github.com/acme/web" })
        try actions.restore(contentID: removed.contentID)
        session = try #require(try fixture.service.sessions().first)
        #expect(session.eventCount == 2)
        #expect(session.topEntities.contains { $0.value == "github.com/acme/web" })
    }

    @Test func deletingRecutsSessionsAndDropsTheDeletedContextFromExplanations() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "x", minute: 0, url: "https://a.example/p")
        try copy(fixture, "y", minute: 1, url: "https://a.example/q")
        let p1 = try copy(fixture, "z", minute: 2, url: "https://private.example.org/1")
        let p2 = try copy(fixture, "w", minute: 3, url: "https://private.example.org/2")
        #expect(
            try fixture.service.sessions().map(\.explanation).contains {
                $0.contains("private.example.org")
            })

        let actions = ItemActions(database: fixture.database)
        try actions.delete(contentID: p1.contentID)
        try actions.delete(contentID: p2.contentID)
        let afterDelete = try fixture.service.sessions()
        #expect(afterDelete.count == 1)
        #expect(afterDelete.allSatisfy { !$0.explanation.contains("private.example.org") })

        try actions.restore(contentID: p1.contentID)
        try actions.restore(contentID: p2.contentID)
        #expect(try fixture.service.sessions().count == 2)
    }

    private func fullState(_ fixture: Fixture) throws -> [String] {
        try fixture.database.read { connection in
            try connection.query(
                """
                SELECT id, started_at, event_count, start_reason, start_detail, topic_id
                FROM sessions ORDER BY started_at, first_event_id
                """
            ) { row in
                (0..<6).map { column in
                    row.isNull(Int32(column))
                        ? "-" : (column == 1 ? String(row.double(1)) : row.text(Int32(column)))
                }.joined(separator: "|")
            }
        }
    }

    /// Context switch whose confirmation arrives only after several app-switch sessions.
    private func lookaheadStream(_ fixture: Fixture) throws -> RecordedCopy {
        try copy(fixture, "a1", minute: 0, app: "T", url: "https://a.example/1")
        try copy(fixture, "a2", minute: 1, app: "T", url: "https://a.example/2")
        try copy(fixture, "b1", minute: 2, app: "T", url: "https://secret.example/1")
        try copy(fixture, "n1", minute: 13, app: "X")
        try copy(fixture, "n2", minute: 24, app: "Z")
        return try copy(fixture, "b2", minute: 25, app: "Z", url: "https://secret.example/2")
    }

    @Test func incrementalAssignmentMatchesARebuildWhenAContextIsConfirmedLate() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try lookaheadStream(fixture)
        let incremental = try shape(fixture.service)
        try fixture.service.rebuild()
        #expect(try shape(fixture.service) == incremental)
    }

    @Test func deleteRecutEqualsARebuildEvenWhenTheLookaheadReachesFarBack() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let confirming = try lookaheadStream(fixture)
        try fixture.service.rebuild()
        try ItemActions(database: fixture.database).delete(contentID: confirming.contentID)
        let recut = try fullState(fixture)
        try fixture.service.rebuild()
        #expect(try fullState(fixture) == recut)
    }

    @Test func restoreRecutEqualsARebuildEvenWhenTheLookaheadReachesFarBack() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let confirming = try lookaheadStream(fixture)
        let actions = ItemActions(database: fixture.database)
        try actions.delete(contentID: confirming.contentID)
        try fixture.service.rebuild()
        try actions.restore(contentID: confirming.contentID)
        let recut = try fullState(fixture)
        try fixture.service.rebuild()
        #expect(try fullState(fixture) == recut)
    }

    @Test func recutOfALateSessionKeepsEarlierSessionsAndTopicsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        var late: RecordedCopy?
        for block in 0..<4 {
            let base = Double(block * 200)
            try copy(
                fixture, "block \(block) one", minute: base, url: "https://site\(block).example/a")
            late = try copy(
                fixture, "block \(block) two", minute: base + 1,
                url: "https://site\(block).example/b")
        }
        try fixture.database.write { connection in
            try connection.execute("INSERT INTO topics (label, created_at) VALUES ('t', 0)")
            try connection.execute(
                "UPDATE sessions SET topic_id = ?", [.int(connection.lastInsertRowID)])
        }
        let before = try fullState(fixture)
        try ItemActions(database: fixture.database).delete(contentID: try #require(late).contentID)
        let after = try fullState(fixture)
        #expect(after.count == before.count)
        #expect(Array(after.dropLast()) == Array(before.dropLast()))
        try fixture.service.rebuild()
        #expect(try fullState(fixture).dropLast() == after.dropLast())
    }

    @Test func aFailingRecutDoesNotBlockTheDeleteAndFlagsARebuild() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let first = try copy(fixture, "one", minute: 0)
        try copy(fixture, "two", minute: 1)
        try fixture.database.write { connection in
            // A trigger that makes every session update fail simulates a broken re-cut.
            try connection.execute(
                "CREATE TRIGGER fail_session_update BEFORE UPDATE ON sessions BEGIN SELECT RAISE(ABORT, 'boom'); END"
            )
        }
        #expect(try ItemActions(database: fixture.database).delete(contentID: first.contentID))
        let deletedAt = try fixture.database.read {
            try $0.query("SELECT deleted_at FROM contents WHERE id = ?", [.int(first.contentID)]) {
                $0.optionalText(0)
            }
        }
        #expect(deletedAt.first.flatMap { $0 } != nil)
        try fixture.database.write { try $0.execute("DROP TRIGGER fail_session_update") }
        #expect(try fixture.service.rebuildIfNeeded())
    }

    @Test func contextConfirmationSkipsCopiesWithoutContext() {
        let events = [
            SessionEvent(id: 1, time: Date(timeIntervalSince1970: 0), context: "a"),
            SessionEvent(id: 2, time: Date(timeIntervalSince1970: 60), context: "b"),
            SessionEvent(id: 3, time: Date(timeIntervalSince1970: 120)),
            SessionEvent(id: 4, time: Date(timeIntervalSince1970: 180), context: "b"),
        ]
        #expect(SessionSegmenter.segment(events).map { $0.events.map(\.id) } == [[1], [2, 3, 4]])
    }

    @Test func sessionsStartingAtTheSameTimeAreAllPaged() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try copy(fixture, "https://github.com/acme/api/1", minute: 0)
        try copy(fixture, "https://github.com/acme/web/2", minute: 0)
        try copy(fixture, "https://github.com/acme/web/3", minute: 0)
        let all = try fixture.service.sessions()
        #expect(all.count == 2)
        let paged = try fixture.service.sessions(limit: 1)
        #expect(try fixture.service.sessions(limit: 1, after: paged[0]).map(\.id) == [all[1].id])
    }

    @Test func rebuildIfNeededRepairsUnassignedEventsAndFlags() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let bulk = ContentStore(database: database, sessions: nil)
        _ = try bulk.record(text: "imported one", copiedAt: at(0))
        _ = try bulk.record(text: "imported two", copiedAt: at(200))
        let service = SessionService(database: database)
        #expect(try service.rebuildIfNeeded())
        #expect(try service.sessions().count == 2)
        #expect(try service.rebuildIfNeeded() == false)
        try database.write { try SessionService.markDirty(in: $0) }
        #expect(try service.rebuildIfNeeded())
        #expect(try service.rebuildIfNeeded() == false)
    }

    @Test func aFreshCopyAfterABulkImportRebuildsInsteadOfLeavingGaps() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        _ = try ContentStore(database: database, sessions: nil).record(
            text: "bulk", copiedAt: at(0))
        _ = try ContentStore(database: database).record(text: "live", copiedAt: at(5))
        let unassigned = try database.read {
            try $0.query("SELECT count(*) FROM copy_events WHERE session_id IS NULL") { $0.int(0) }
        }
        #expect(unassigned == [0])
    }

    @Test func configurationEdgesAreClamped() {
        let zero = SessionConfiguration(gapMinutes: 0)
        #expect(zero.gap == 0 && zero.appSwitchGap == 0)
        #expect(SessionConfiguration(gapMinutes: 5, appSwitchGapMinutes: 50).appSwitchGap == 300)
        #expect(SessionConfiguration(contextConfirmations: 0).contextConfirmations == 1)
    }
}

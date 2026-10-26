import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct ItemActionsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let store: ContentStore
        let actions: ItemActions
        let ranking: RankingService
        let search: SearchService
        let database: Database
        let temp: TemporaryDatabase

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
            actions = ItemActions(database: database)
            ranking = RankingService(database: database)
            search = SearchService(database: database)
        }
    }

    private func total(_ fixture: Fixture, _ id: Int64, _ name: String) throws -> Double {
        let explanation = try #require(try fixture.ranking.explain(contentID: id, now: now))
        return try #require(explanation.components.first { $0.name == name }).value
    }

    @Test func pinOverridesDecayAndRetention() throws {
        let configuration = RankingConfiguration(policy: TierPolicy(archiveRetentionDays: 100))
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database, ranking: configuration)
        let old = try store.record(
            text: "pinned forever note", copiedAt: now.addingTimeInterval(-900 * 86_400))
        try ItemActions(database: database, configuration: configuration)
            .setPinned(true, contentID: old.contentID, now: now)
        let ranking = RankingService(database: database, configuration: configuration)
        try ranking.refreshAll(now: now)
        #expect(try ranking.applyRetention(now: now) == 0)
        let explanation = try #require(try ranking.explain(contentID: old.contentID, now: now))
        #expect(explanation.tier == .hot)
        #expect(explanation.importance == 1)
    }

    @Test func starAddsABonusButStillFades() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copy = try fixture.store.record(text: "starred snippet text", copiedAt: now)
        #expect(try fixture.actions.setStarred(true, contentID: copy.contentID, now: now))
        #expect(try total(fixture, copy.contentID, "star") == ScoringWeights().star)
        #expect(try fixture.actions.setStarred(false, contentID: copy.contentID, now: now))
        #expect(try total(fixture, copy.contentID, "star") == 0)
        try fixture.ranking.refreshAll(now: now.addingTimeInterval(200 * 86_400))
        try fixture.actions.setStarred(
            true, contentID: copy.contentID, now: now.addingTimeInterval(200 * 86_400))
        let tier = try fixture.database.read {
            try $0.query("SELECT tier FROM contents") { $0.text(0) }
        }
        #expect(tier == ["archive"])
    }

    @Test func deletedItemsDisappearFromSearchAndListingAndComeBackOnRestore() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let keep = try fixture.store.record(text: "alpha keeper text", copiedAt: now)
        let gone = try fixture.store.record(text: "alpha removed text", copiedAt: now)
        #expect(try fixture.actions.delete(contentID: gone.contentID, now: now))

        #expect(try fixture.search.search("alpha").map(\.contentID) == [keep.contentID])
        #expect(try fixture.search.search("").map(\.contentID) == [keep.contentID])
        #expect(try fixture.search.search("a").map(\.contentID) == [keep.contentID])

        #expect(try fixture.actions.restore(contentID: gone.contentID, now: now))
        #expect(try fixture.search.search("alpha").count == 2)
    }

    @Test func copyingADeletedTextAgainRestoresIt() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let first = try fixture.store.record(text: "deleted then copied again", copiedAt: now)
        try fixture.actions.delete(contentID: first.contentID, now: now)
        let again = try fixture.store.record(text: "deleted then copied again", copiedAt: now)
        #expect(again.contentID == first.contentID)
        #expect(try fixture.search.search("copied again").count == 1)
    }

    @Test func purgeRemovesOnlyOldDeletionsAndKeepsTheFeedbackLog() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let old = try fixture.store.record(text: "deleted long ago", copiedAt: now)
        let recent = try fixture.store.record(text: "deleted just now", copiedAt: now)
        let live = try fixture.store.record(text: "never deleted", copiedAt: now)
        try fixture.actions.delete(
            contentID: old.contentID, now: now.addingTimeInterval(-40 * 86_400))
        try fixture.actions.delete(
            contentID: recent.contentID, now: now.addingTimeInterval(-1 * 86_400))

        #expect(try fixture.actions.purgeDeleted(olderThanDays: 30, now: now) == 1)
        let remaining = try fixture.database.read {
            try $0.query("SELECT id FROM contents ORDER BY id") { $0.int(0) }
        }
        #expect(remaining == [recent.contentID, live.contentID])
        let orphanedEvents = try fixture.database.read {
            try $0.query("SELECT count(*) FROM feedback_events WHERE content_id IS NULL") {
                $0.int(0)
            }
        }
        #expect(orphanedEvents == [1])
    }

    @Test func feedbackStepsMoveTheScoreAndAreClamped() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copy = try fixture.store.record(text: "feedback target text", copiedAt: now)
        for _ in 0..<5 { try fixture.actions.moreLikeThis(contentID: copy.contentID, now: now) }
        #expect(
            try total(fixture, copy.contentID, "feedback")
                == ScoringWeights().feedback * Double(ItemActions.feedbackLimit))
        for _ in 0..<10 { try fixture.actions.lessLikeThis(contentID: copy.contentID, now: now) }
        #expect(
            try total(fixture, copy.contentID, "feedback")
                == -ScoringWeights().feedback * Double(ItemActions.feedbackLimit))
    }

    @Test func everyActionIsPersistedWithFeatures() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copy = try fixture.store.record(
            text: "ls -la /var/log", copiedAt: now,
            context: CopyContext(appBundleID: "com.apple.Terminal"))
        let id = copy.contentID
        try fixture.actions.setPinned(true, contentID: id, now: now)
        try fixture.actions.setPinned(false, contentID: id, now: now)
        try fixture.actions.setStarred(true, contentID: id, now: now)
        try fixture.actions.setStarred(false, contentID: id, now: now)
        try fixture.actions.moreLikeThis(contentID: id, now: now)
        try fixture.actions.lessLikeThis(contentID: id, now: now)
        try fixture.actions.delete(contentID: id, now: now)
        try fixture.actions.restore(contentID: id, now: now)

        let events = try fixture.actions.events(contentID: id)
        #expect(
            events.map(\.action) == [.pin, .unpin, .star, .unstar, .more, .less, .delete, .restore])
        #expect(events.allSatisfy { $0.appBundleID == "com.apple.Terminal" && $0.copyCount == 1 })
        #expect(events.allSatisfy { $0.kind == "command" && $0.createdAt == now })
        #expect(events[0].importance == 1)
    }

    @Test func actionsOnMissingItemsDoNothing() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        #expect(try fixture.actions.setPinned(true, contentID: 42, now: now) == false)
        #expect(try fixture.actions.delete(contentID: 42, now: now) == false)
        let logged = try fixture.database.read {
            try $0.query("SELECT count(*) FROM feedback_events") { $0.int(0) }
        }
        #expect(logged == [0])
    }

    @Test func deletingTwiceKeepsTheFirstDeletionTime() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let copy = try fixture.store.record(text: "deleted twice text", copiedAt: now)
        try fixture.actions.delete(contentID: copy.contentID, now: now)
        try fixture.actions.delete(contentID: copy.contentID, now: now.addingTimeInterval(5_000))
        let stamp = try fixture.database.read {
            try $0.query("SELECT deleted_at FROM contents") { $0.double(0) }
        }
        #expect(stamp == [now.timeIntervalSince1970])
    }
}

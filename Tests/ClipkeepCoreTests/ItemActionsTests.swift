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

    private func componentValue(_ fixture: Fixture, _ id: Int64, _ name: String) throws -> Double {
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
        #expect(try componentValue(fixture, copy.contentID, "star") == ScoringWeights().star)
        let fresh = try #require(try fixture.ranking.explain(contentID: copy.contentID, now: now))
        let later = now.addingTimeInterval(200 * 86_400)
        let faded = try #require(try fixture.ranking.explain(contentID: copy.contentID, now: later))
        #expect(faded.total < fresh.total)
        #expect(faded.tier == .archive)
        #expect(faded.importance < 1)

        #expect(try fixture.actions.setStarred(false, contentID: copy.contentID, now: now))
        #expect(try componentValue(fixture, copy.contentID, "star") == 0)
    }

    @Test func scorerAppliesStarAndFeedbackComponents() {
        let input = ScoreInput(
            copyDates: [now], copyCount: 1, kind: .text, characterCount: 100, isStarred: true,
            feedbackSteps: -2)
        let explanation = Scorer.explain(input, now: now)
        let values = Dictionary(
            uniqueKeysWithValues: explanation.components.map { ($0.name, $0.value) })
        #expect(values["star"] == 3)
        #expect(values["feedback"] == -3)
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
        try fixture.actions.setPinned(true, contentID: gone.contentID, now: now)
        let byImportance = SearchFilter(listingOrder: .importance)
        #expect(
            try fixture.search.search("", filter: byImportance).map(\.contentID) == [keep.contentID]
        )
        let filtered = SearchFilter(copiedAfter: now.addingTimeInterval(-10), kind: "text")
        #expect(
            try fixture.search.search("alpha", filter: filtered).map(\.contentID) == [
                keep.contentID
            ])

        #expect(try fixture.actions.restore(contentID: gone.contentID, now: now))
        #expect(try fixture.search.search("alpha").count == 2)
    }

    @Test func copyingADeletedTextAgainRestoresIt() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let first = try fixture.store.record(text: "deleted then copied again", copiedAt: now)
        try fixture.actions.delete(contentID: first.contentID, now: now)
        try fixture.actions.setPinned(true, contentID: first.contentID, now: now)
        try fixture.actions.delete(contentID: first.contentID, now: now)
        let again = try fixture.store.record(text: "deleted then copied again", copiedAt: now)
        #expect(again.contentID == first.contentID)
        #expect(try fixture.search.search("copied again").count == 1)
        let events = try fixture.actions.events(contentID: first.contentID)
        #expect(events.map(\.action) == [.delete, .pin, .recopy])
        // The pin survives the round trip.
        let explanation = try #require(
            try fixture.ranking.explain(contentID: first.contentID, now: now))
        #expect(explanation.importance == 1)
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
            try componentValue(fixture, copy.contentID, "feedback")
                == ScoringWeights().feedback * Double(ItemActions.feedbackLimit))
        for _ in 0..<10 { try fixture.actions.lessLikeThis(contentID: copy.contentID, now: now) }
        #expect(
            try componentValue(fixture, copy.contentID, "feedback")
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
        // The snapshot is taken before the action: pinning does not leak into its own features.
        #expect(events[0].importance < 1)
    }

    @Test func actionsOnMissingItemsDoNothing() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        #expect(try fixture.actions.setPinned(true, contentID: 42, now: now) == false)
        #expect(try fixture.actions.delete(contentID: 42, now: now) == false)
        #expect(try fixture.actions.restore(contentID: 42, now: now) == false)
        #expect(try fixture.actions.setStarred(true, contentID: 42, now: now) == false)
        #expect(try fixture.actions.moreLikeThis(contentID: 42, now: now) == false)
        #expect(try fixture.actions.lessLikeThis(contentID: 42, now: now) == false)
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
        #expect(try fixture.actions.events(contentID: copy.contentID).map(\.action) == [.delete])
        let stamp = try fixture.database.read {
            try $0.query("SELECT deleted_at FROM contents") { $0.double(0) }
        }
        #expect(stamp == [now.timeIntervalSince1970])
    }

    @Test func repeatedAndNoOpActionsAreNotLogged() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try fixture.store.record(text: "idempotent actions text", copiedAt: now).contentID
        try fixture.actions.restore(contentID: id, now: now)
        try fixture.actions.setPinned(false, contentID: id, now: now)
        try fixture.actions.setPinned(true, contentID: id, now: now)
        try fixture.actions.setPinned(true, contentID: id, now: now)
        for _ in 0..<5 { try fixture.actions.moreLikeThis(contentID: id, now: now) }
        let actions = try fixture.actions.events(contentID: id).map(\.action)
        #expect(actions == [.pin, .more, .more, .more])
    }

    @Test func duplicateLinksHideDeletedItems() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let first = try fixture.store.record(text: "Hello   World", copiedAt: now)
        try fixture.actions.delete(contentID: first.contentID, now: now)
        let second = try fixture.store.record(text: "hello world", copiedAt: now)
        // Deleted items neither link nor use up the link budget.
        #expect(try fixture.store.duplicateLinks(of: second.contentID).isEmpty)
        try fixture.actions.restore(contentID: first.contentID, now: now)
        let third = try fixture.store.record(text: "HELLO WORLD", copiedAt: now)
        #expect(
            try fixture.store.duplicateLinks(of: third.contentID).map(\.relatedID).contains(
                first.contentID))
        try fixture.actions.delete(contentID: first.contentID, now: now)
        #expect(
            try fixture.store.duplicateLinks(of: third.contentID).allSatisfy {
                $0.relatedID != first.contentID
            })
    }

    @Test func retentionSparesStarredAndDeletedItems() throws {
        let configuration = RankingConfiguration(policy: TierPolicy(archiveRetentionDays: 100))
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(database: database, ranking: configuration)
        let actions = ItemActions(database: database, configuration: configuration)
        let long = now.addingTimeInterval(-400 * 86_400)
        let starred = try store.record(text: "starred and ancient", copiedAt: long)
        let deleted = try store.record(text: "deleted and ancient", copiedAt: long)
        let plain = try store.record(text: "plain and ancient", copiedAt: long)
        try actions.setStarred(true, contentID: starred.contentID, now: now)
        try actions.delete(contentID: deleted.contentID, now: now)

        let ranking = RankingService(database: database, configuration: configuration)
        #expect(try ranking.applyRetention(now: now) == 1)
        let remaining = try database.read {
            try $0.query("SELECT id FROM contents ORDER BY id") { $0.int(0) }
        }
        #expect(remaining == [starred.contentID, deleted.contentID])
        #expect(plain.contentID != starred.contentID)
        // The user can still undo the deletion, and an explicit purge removes the dependent rows.
        #expect(try actions.restore(contentID: deleted.contentID, now: now))
        try actions.delete(contentID: deleted.contentID, now: now)
        #expect(try actions.purgeDeleted(olderThanDays: 0, now: now) == 1)
        for table in ["copy_events", "entities", "content_bands"] {
            let rows = try database.read {
                try $0.query(
                    "SELECT count(*) FROM \(table) WHERE content_id = ?", [.int(deleted.contentID)]
                ) { $0.int(0) }
            }
            #expect(rows == [0], "\(table) should be cleaned up")
        }
    }
}

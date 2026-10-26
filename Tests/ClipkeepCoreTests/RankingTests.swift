import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct ScorerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ value: Double) -> Date { now.addingTimeInterval(-value * 86_400) }

    private func input(
        ages: [Double] = [0], count: Int? = nil, kind: ContentKind = .text, characters: Int = 100,
        app: String? = nil, pinned: Bool = false
    ) -> ScoreInput {
        ScoreInput(
            copyDates: ages.map(days), copyCount: count ?? ages.count, kind: kind,
            characterCount: characters, latestAppBundleID: app, isPinned: pinned)
    }

    private func value(_ name: String, _ explanation: ScoreExplanation) -> Double {
        explanation.components.first { $0.name == name }?.value ?? .nan
    }

    @Test func frecencyHalvesEveryHalfLife() {
        let fresh = Scorer.explain(input(ages: [0]), now: now)
        let weekOld = Scorer.explain(input(ages: [7]), now: now)
        #expect(abs(value("frecency", weekOld) - value("frecency", fresh) / 2) < 1e-9)
    }

    @Test func frecencyIsCappedAndIgnoresFutureDates() {
        let many = Scorer.explain(input(ages: Array(repeating: 0, count: 50)), now: now)
        #expect(value("frecency", many) == ScoringWeights().frecency * Scorer.maximumFrecency)
        let future = Scorer.explain(input(ages: [-5]), now: now)
        #expect(value("frecency", future) == ScoringWeights().frecency)
    }

    @Test func repetitionGrowsLogarithmically() {
        #expect(value("repetition", Scorer.explain(input(count: 1), now: now)) == 0)
        #expect(value("repetition", Scorer.explain(input(count: 8), now: now)) == 3)
    }

    @Test func kindWeightIsApplied() {
        #expect(value("kind", Scorer.explain(input(kind: .command), now: now)) == 1)
        #expect(value("kind", Scorer.explain(input(kind: .number), now: now)) == -0.5)
        #expect(value("kind", Scorer.explain(input(kind: .text), now: now)) == 0)
    }

    @Test(arguments: [
        (1, -1.0), (3, -1.0), (20, 1.0), (500, 1.0), (2_000, 1.0), (100_000, -1.0),
        (5_000_000, -1.0),
    ])
    func lengthBandPoints(characters: Int, expected: Double) {
        #expect(abs(Scorer.lengthBand(characters) - expected) < 1e-9)
    }

    @Test func lengthBandIsMonotonicOnEachRamp() {
        #expect(Scorer.lengthBand(10) > Scorer.lengthBand(5))
        #expect(Scorer.lengthBand(50_000) < Scorer.lengthBand(5_000))
    }

    @Test func appWeightUsesTheLatestApp() {
        var weights = ScoringWeights()
        weights.apps["com.apple.Terminal"] = 2
        let terminal = Scorer.explain(input(app: "com.apple.Terminal"), weights: weights, now: now)
        let other = Scorer.explain(input(app: "com.example.Other"), weights: weights, now: now)
        #expect(value("app", terminal) == 2)
        #expect(value("app", other) == 0)
    }

    @Test func pinDominatesAndForcesFullImportanceAndHotTier() {
        let pinned = Scorer.explain(input(ages: [900], pinned: true), now: now)
        let loose = Scorer.explain(input(ages: [0], kind: .command), now: now)
        #expect(pinned.total > loose.total)
        #expect(pinned.importance == 1)
        #expect(pinned.tier == .hot)
    }

    @Test func zeroWeightsSwitchSignalsOff() {
        var weights = ScoringWeights()
        weights.frecency = 0
        weights.repetition = 0
        weights.length = 0
        weights.kinds = [:]
        let explanation = Scorer.explain(
            input(ages: [0, 1, 2], kind: .command), weights: weights, now: now)
        #expect(explanation.total == 0)
    }

    @Test func importanceStaysWithinZeroAndOne() {
        for age in [0.0, 1, 30, 3_000] {
            let importance = Scorer.explain(input(ages: [age]), now: now).importance
            #expect((0...1).contains(importance))
        }
    }

    @Test func explanationNamesEverySignal() {
        let names = Scorer.explain(input(), now: now).components.map(\.name)
        #expect(names == ["frecency", "repetition", "kind", "length", "app", "pin"])
        #expect(Scorer.explain(input(), now: now).components.allSatisfy { !$0.detail.isEmpty })
    }

    @Test(arguments: [
        (0.0, Tier.hot), (7.0, Tier.hot), (7.5, Tier.warm), (60.0, Tier.warm), (61.0, Tier.archive),
    ])
    func tierTransitions(age: Double, expected: Tier) {
        #expect(Scorer.explain(input(ages: [age]), now: now).tier == expected)
    }

    @Test func policyClampsInconsistentValues() {
        let policy = TierPolicy(hotDays: 30, warmDays: 10, archiveRetentionDays: 5)
        #expect(policy.warmDays == 30)
        #expect(policy.archiveRetentionDays == 30)
        #expect(TierPolicy().archiveRetentionDays == nil)
    }
}

@Suite struct RankingServiceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * 86_400) }

    private func makeFixture(_ configuration: RankingConfiguration = .default) throws -> (
        ContentStore, RankingService, Database, TemporaryDatabase
    ) {
        let temp = try TemporaryDatabase()
        let database = try temp.open()
        return (
            ContentStore(database: database, ranking: configuration),
            RankingService(database: database, configuration: configuration), database, temp
        )
    }

    private func tier(_ id: Int64, _ database: Database) throws -> String? {
        try database.read {
            try $0.query("SELECT tier FROM contents WHERE id = ?", [.int(id)]) { $0.text(0) }.first
        }
    }

    @Test func recordStoresAnExplainableScore() throws {
        let (store, ranking, _, temp) = try makeFixture()
        defer { temp.remove() }
        let copy = try store.record(
            text: "git rebase --onto main feature~3 feature", copiedAt: now,
            context: CopyContext(appBundleID: "com.apple.Terminal"))
        let explanation = try #require(try ranking.explain(contentID: copy.contentID, now: now))
        #expect(explanation.components.first { $0.name == "app" }?.detail == "com.apple.Terminal")
        #expect(explanation.importance > 0)
        #expect(try ranking.explain(contentID: 9_999, now: now) == nil)
    }

    @Test func repeatedCopiesRaiseImportance() throws {
        let (store, ranking, _, temp) = try makeFixture()
        defer { temp.remove() }
        let once = try store.record(text: "only once in history", copiedAt: now)
        var repeated = try store.record(text: "copied again and again", copiedAt: now)
        for _ in 0..<5 {
            repeated = try store.record(text: "copied again and again", copiedAt: now)
        }
        let single = try #require(try ranking.explain(contentID: once.contentID, now: now))
        let many = try #require(try ranking.explain(contentID: repeated.contentID, now: now))
        #expect(many.importance > single.importance)
    }

    @Test func refreshMovesItemsThroughTheTiers() throws {
        let (store, ranking, database, temp) = try makeFixture()
        defer { temp.remove() }
        let copy = try store.record(text: "an aging snippet worth keeping", copiedAt: now)
        #expect(try tier(copy.contentID, database) == "hot")
        #expect(try ranking.refreshAll(now: at(daysAgo: -30)) == 1)
        #expect(try tier(copy.contentID, database) == "warm")
        #expect(try ranking.refreshAll(now: at(daysAgo: -200)) == 1)
        #expect(try tier(copy.contentID, database) == "archive")
        #expect(try ranking.refreshAll(now: at(daysAgo: -200)) == 0)
    }

    @Test func pinKeepsAnOldItemHot() throws {
        let (store, ranking, database, temp) = try makeFixture()
        defer { temp.remove() }
        let copy = try store.record(text: "pinned for the long run", copiedAt: at(daysAgo: 400))
        try ranking.setPinned(true, contentID: copy.contentID, now: now)
        try ranking.refreshAll(now: now)
        #expect(try tier(copy.contentID, database) == "hot")
        try ranking.setPinned(false, contentID: copy.contentID, now: now)
        #expect(try tier(copy.contentID, database) == "archive")
    }

    @Test func nothingIsDeletedByDefault() throws {
        let (store, ranking, _, temp) = try makeFixture()
        defer { temp.remove() }
        let copy = try store.record(text: "ancient but kept", copiedAt: at(daysAgo: 5_000))
        #expect(try ranking.applyRetention(now: now) == 0)
        #expect(try ranking.explain(contentID: copy.contentID, now: now) != nil)
    }

    @Test func retentionDeletesOnlyOldUnpinnedItemsWhenEnabled() throws {
        let configuration = RankingConfiguration(policy: TierPolicy(archiveRetentionDays: 365))
        let (store, ranking, _, temp) = try makeFixture(configuration)
        defer { temp.remove() }
        let old = try store.record(text: "expired snippet content", copiedAt: at(daysAgo: 400))
        let pinned = try store.record(
            text: "pinned old snippet content", copiedAt: at(daysAgo: 400))
        let young = try store.record(text: "recent snippet content", copiedAt: at(daysAgo: 100))
        try ranking.setPinned(true, contentID: pinned.contentID, now: now)

        #expect(try ranking.applyRetention(now: now) == 1)
        #expect(try ranking.explain(contentID: old.contentID, now: now) == nil)
        #expect(try ranking.explain(contentID: pinned.contentID, now: now) != nil)
        #expect(try ranking.explain(contentID: young.contentID, now: now) != nil)
    }

    @Test func searchPrefersImportantItemsOfEqualRelevance() throws {
        let (store, ranking, database, temp) = try makeFixture()
        defer { temp.remove() }
        let plain = try store.record(text: "deploy notes alpha", copiedAt: now)
        let favourite = try store.record(text: "deploy notes bravo", copiedAt: at(daysAgo: 30))
        try ranking.setPinned(true, contentID: favourite.contentID, now: now)

        let hits = try SearchService(database: database).search("deploy notes")
        #expect(hits.map(\.contentID) == [favourite.contentID, plain.contentID])
        let listing = try SearchService(database: database).search("")
        #expect(listing.first?.contentID == favourite.contentID)
    }
}

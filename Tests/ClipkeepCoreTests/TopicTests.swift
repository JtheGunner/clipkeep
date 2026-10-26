import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct TermTokenizerTests {
    @Test func splitsIdentifiersAndLowercases() {
        let counts = TermTokenizer.counts(
            in: "getUserData and parse_http_response, getUserData again")
        #expect(counts["user"] == 2)
        #expect(counts["data"] == 2)
        #expect(counts["http"] == 1)
        #expect(counts["response"] == 1)
    }

    @Test func dropsStopWordsShortTokensAndNumbers() {
        let english = TermTokenizer.counts(
            in: "The server and the client are running on 8080 at 12")
        #expect(english["the"] == nil && english["and"] == nil && english["are"] == nil)
        #expect(english["8080"] == nil && english["12"] == nil)
        #expect(english["server"] == 1 && english["client"] == 1)
    }

    @Test func usesGermanStopWordsForGermanText() {
        let counts = TermTokenizer.counts(
            in:
                "Die Rechnung ist nicht bezahlt und der Kunde wartet auf eine Antwort von der Buchhaltung"
        )
        #expect(counts["die"] == nil && counts["nicht"] == nil && counts["und"] == nil)
        #expect(counts["rechnung"] == 1 && counts["buchhaltung"] == 1)
    }

    @Test func emptyAndHugeInputsAreSafe() {
        #expect(TermTokenizer.counts(in: "").isEmpty)
        let huge = String(repeating: "alpha beta gamma ", count: 100_000)
        #expect(TermTokenizer.counts(in: huge)["alpha"] ?? 0 > 0)
    }
}

@Suite struct TopicClustererTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func document(
        _ id: Int64, _ words: String, features: [String] = [], day: Double = 0
    ) -> TopicDocument {
        var counts: [String: Int] = [:]
        for word in words.split(separator: " ") { counts[String(word), default: 0] += 1 }
        return TopicDocument(
            id: id, time: base.addingTimeInterval(day * 86_400), terms: counts, features: features)
    }

    private let swiftWords = "swift package manifest target dependency xcode build compiler"
    private let kubeWords = "kubernetes pod deployment ingress helm chart cluster namespace"

    @Test func similarDocumentsShareATopicAndUnrelatedOnesDoNot() {
        let documents = [
            document(1, swiftWords, day: 0), document(2, swiftWords + " test", day: 1),
            document(3, kubeWords, day: 2),
        ]
        let placements = TopicClusterer.place(free: documents, fixed: [:], corpus: documents)
        guard case .new(let first, _) = placements[1],
            case .new(let second, let reason) = placements[2],
            case .new(let third, _) = placements[3]
        else {
            Issue.record("expected new groups")
            return
        }
        #expect(first == second)
        #expect(first != third)
        let shared = reason?.sharedTerms ?? []
        let allowed = Set(swiftWords.split(separator: " ").map(String.init))
        #expect(!shared.isEmpty)
        #expect(Set(shared).isSubset(of: allowed))
    }

    @Test func structuralSignalsOutweighDifferentWords() {
        let repo = "repo:github.com/acme/api"
        let documents = [
            document(1, swiftWords, features: [repo], day: 0),
            document(2, kubeWords, features: [repo], day: 1),
        ]
        let placements = TopicClusterer.place(free: documents, fixed: [:], corpus: documents)
        guard case .new(let a, _) = placements[1], case .new(let b, let reason) = placements[2]
        else {
            Issue.record("expected new groups")
            return
        }
        #expect(a == b)
        #expect(reason?.sharedFeatures == [repo])
        #expect(reason?.text.contains("gleiches Repo github.com/acme/api") == true)
    }

    @Test func withoutStructuralWeightTheSameDocumentsStaySeparate() {
        let repo = "repo:github.com/acme/api"
        let documents = [
            document(1, swiftWords, features: [repo]),
            document(2, kubeWords, features: [repo], day: 1),
        ]
        let plain = TopicConfiguration(structuralWeight: 0)
        let placements = TopicClusterer.place(
            free: documents, fixed: [:], corpus: documents, configuration: plain)
        guard case .new(let a, _) = placements[1], case .new(let b, _) = placements[2]
        else {
            Issue.record("expected new groups")
            return
        }
        #expect(a != b)
    }

    @Test func fixedSessionsSeedExistingTopics() {
        let documents = [document(1, swiftWords), document(2, swiftWords + " test", day: 1)]
        let placements = TopicClusterer.place(
            free: [documents[1]], fixed: [1: 42], corpus: documents)
        guard case .existing(let topic, let reason) = placements[2] else {
            Issue.record("expected existing topic")
            return
        }
        #expect(topic == 42)
        #expect(reason.similarity > 0.5)
        #expect(reason.text.contains("Ähnlichkeit"))
    }

    @Test func thresholdIsConfigurable() {
        let documents = [
            document(1, swiftWords), document(2, "swift " + kubeWords, day: 1),
        ]
        let strict = TopicClusterer.place(
            free: documents, fixed: [:], corpus: documents,
            configuration: TopicConfiguration(similarityThreshold: 0.9))
        let loose = TopicClusterer.place(
            free: documents, fixed: [:], corpus: documents,
            configuration: TopicConfiguration(similarityThreshold: 0.01))
        guard case .new(let strictA, _) = strict[1], case .new(let strictB, _) = strict[2],
            case .new(let looseA, _) = loose[1], case .new(let looseB, _) = loose[2]
        else {
            Issue.record("expected new groups")
            return
        }
        #expect(strictA != strictB)
        #expect(looseA == looseB)
    }

    @Test func resultsAreDeterministicAndIndependentOfInputOrder() {
        let documents = (0..<12).map {
            document(Int64($0), $0 % 2 == 0 ? swiftWords : kubeWords, day: Double($0))
        }
        let forward = TopicClusterer.place(free: documents, fixed: [:], corpus: documents)
        let reversed = TopicClusterer.place(
            free: documents.reversed(), fixed: [:], corpus: documents)
        #expect(forward == reversed)
    }

    @Test func emptyDocumentsNeverMatch() {
        let documents = [document(1, ""), document(2, "", day: 1)]
        let placements = TopicClusterer.place(free: documents, fixed: [:], corpus: documents)
        guard case .new(let a, _) = placements[1], case .new(let b, _) = placements[2]
        else {
            Issue.record("expected new groups")
            return
        }
        #expect(a != b)
        #expect(TopicClusterer.place(free: [], fixed: [:], corpus: []).isEmpty)
    }

    @Test func keywordsListStrongestFeaturesAndTerms() {
        let documents = [
            document(1, swiftWords, features: ["repo:github.com/acme/api"]),
            document(2, swiftWords, features: ["repo:github.com/acme/api"], day: 1),
            document(3, kubeWords, day: 2),
        ]
        let result = TopicClusterer.keywords(
            of: Array(documents.prefix(2)),
            idf: TopicClusterer.inverseDocumentFrequencies(documents))
        #expect(result.features == ["repo:github.com/acme/api"])
        #expect(result.terms.count == 5)
        #expect(
            Set(result.terms).isSubset(of: Set(swiftWords.split(separator: " ").map(String.init))))
    }
}

@Suite struct TopicServiceTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let swiftText = [
        "swift package manifest target dependency", "xcode build compiler swift target",
        "package dependency resolve swift manifest",
    ]
    private let kubeText = [
        "kubernetes pod deployment ingress", "helm chart cluster namespace kubernetes",
        "ingress deployment pod cluster helm",
    ]

    private struct Fixture {
        let store: ContentStore
        let sessions: SessionService
        let topics: TopicService
        let database: Database
        let temp: TemporaryDatabase

        init(configuration: TopicConfiguration = .default) throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
            sessions = SessionService(database: database)
            topics = TopicService(database: database, configuration: configuration)
        }
    }

    /// Each block is one session, far enough apart from the others to be cut.
    private func fill(_ fixture: Fixture, _ blocks: [[String]], url: String? = nil) throws {
        for (index, texts) in blocks.enumerated() {
            for (offset, text) in texts.enumerated() {
                let time = base.addingTimeInterval(Double(index) * 3 * 3_600 + Double(offset) * 60)
                _ = try fixture.store.record(
                    text: text + " \(index)\(offset)", copiedAt: time,
                    context: CopyContext(url: url))
            }
        }
    }

    private var later: Date { base.addingTimeInterval(30 * 86_400) }

    @Test func groupsSessionsByTopicWithReasonsAndKeywords() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fill(fixture, [swiftText, kubeText, swiftText, kubeText])
        #expect(try fixture.topics.cluster(now: later) == 4)

        let topics = try fixture.topics.topics()
        #expect(topics.count == 2)
        #expect(topics.map(\.sessionCount).sorted() == [2, 2])
        #expect(topics.allSatisfy { !$0.label.isEmpty && !$0.keywords.isEmpty })

        let sessionIDs = try fixture.sessions.sessions().map(\.id)
        let reasons = try sessionIDs.compactMap { try fixture.topics.topic(ofSession: $0) }
        #expect(reasons.count == 4)
        #expect(reasons.allSatisfy { $0.topicID != nil && !$0.reason.isEmpty && !$0.isLocked })
        #expect(reasons.contains { $0.reason.contains("gemeinsame Begriffe") })
    }

    @Test func sameRepoGroupsSessionsWithDifferentWords() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let repoText = "see https://github.com/acme/api/issues/1 "
        try fill(fixture, [[repoText + swiftText[0]], [repoText + kubeText[0]]])
        try fixture.topics.cluster(now: later)
        let topics = try fixture.topics.topics()
        #expect(topics.count == 1)
        #expect(topics[0].label == "github.com/acme/api")
        let newest = try #require(try fixture.sessions.sessions().first)
        let reason = try #require(try fixture.topics.topic(ofSession: newest.id)).reason
        #expect(reason.contains("gleiches Repo github.com/acme/api"))
    }

    @Test func recentSessionsWaitUntilTheyAreSettled() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fill(fixture, [swiftText])
        #expect(try fixture.topics.cluster(now: base.addingTimeInterval(5 * 60)) == 0)
        #expect(try fixture.topics.topics().isEmpty)
        #expect(try fixture.topics.cluster(now: later) == 1)
    }

    @Test func incrementalClusteringKeepsExistingAssignments() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fill(fixture, [swiftText, kubeText])
        try fixture.topics.cluster(now: later)
        let before = try fixture.sessions.sessions().map {
            try fixture.topics.topic(ofSession: $0.id)?.topicID
        }
        _ = try fixture.store.record(
            text: swiftText[0] + " newcomer", copiedAt: base.addingTimeInterval(20 * 86_400))
        #expect(try fixture.topics.cluster(now: later) == 1)
        let after = try fixture.sessions.sessions().dropFirst().map {
            try fixture.topics.topic(ofSession: $0.id)?.topicID
        }
        #expect(Array(after) == before)
        #expect(try fixture.topics.topics().count == 2)
    }

    @Test func reclusterIsIdempotentAndKeepsTopicIDs() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fill(fixture, [swiftText, kubeText, swiftText, kubeText])
        try fixture.topics.cluster(now: later)
        let before = try fixture.topics.topics().map { [$0.id, Int64($0.sessionCount)] }
        try fixture.topics.recluster(now: later)
        try fixture.topics.recluster(now: later)
        #expect(try fixture.topics.topics().map { [$0.id, Int64($0.sessionCount)] } == before)
    }

    @Test func manualCorrectionsSurviveRecomputation() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fill(fixture, [swiftText, kubeText, swiftText, kubeText])
        try fixture.topics.cluster(now: later)

        let sessions = try fixture.sessions.sessions().reversed()  // oldest first
        let ids = sessions.map(\.id)
        let swiftTopic = try #require(try fixture.topics.topic(ofSession: ids[0])?.topicID)

        // Move a Kubernetes session into the Swift topic, split another one off, rename a topic.
        #expect(try fixture.topics.assign(sessionID: ids[3], toTopic: swiftTopic))
        let split = try #require(try fixture.topics.splitOff(sessionID: ids[2]))
        #expect(try fixture.topics.rename(topic: swiftTopic, to: "Cluster-Betrieb"))

        try fixture.topics.recluster(now: later)
        #expect(try fixture.topics.topic(ofSession: ids[3])?.topicID == swiftTopic)
        #expect(try fixture.topics.topic(ofSession: ids[3])?.isLocked == true)
        #expect(try fixture.topics.topic(ofSession: ids[2])?.topicID == split)
        #expect(
            try fixture.topics.topics().first { $0.id == swiftTopic }?.label == "Cluster-Betrieb")
        #expect(try fixture.topics.topics().first { $0.id == swiftTopic }?.labelIsManual == true)
        #expect(try fixture.topics.topic(ofSession: ids[3])?.reason == "Manuell zugeordnet")
    }

    @Test func mergingMovesAndLocksAllSessions() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fill(fixture, [swiftText, kubeText, swiftText, kubeText])
        try fixture.topics.cluster(now: later)
        let topics = try fixture.topics.topics()
        let source = topics[0].id
        let target = topics[1].id
        #expect(try fixture.topics.merge(topic: source, into: target))
        #expect(try fixture.topics.topics().map(\.id) == [target])
        #expect(try fixture.topics.topics()[0].sessionCount == 4)
        try fixture.topics.recluster(now: later)
        #expect(try fixture.topics.topics().map(\.id) == [target])
        #expect(try fixture.topics.merge(topic: target, into: target) == false)
    }

    @Test func emptyLabelReturnsToTheAutomaticOne() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fill(fixture, [swiftText])
        try fixture.topics.cluster(now: later)
        let topic = try #require(try fixture.topics.topics().first)
        let automatic = topic.label
        try fixture.topics.rename(topic: topic.id, to: "Mein Thema")
        #expect(try fixture.topics.topics()[0].label == "Mein Thema")
        try fixture.topics.rename(topic: topic.id, to: "  ")
        #expect(try fixture.topics.topics()[0].label == automatic)
    }

    @Test func manualOperationsOnMissingItemsReturnFalse() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        #expect(try fixture.topics.assign(sessionID: 1, toTopic: 1) == false)
        #expect(try fixture.topics.splitOff(sessionID: 1) == nil)
        #expect(try fixture.topics.merge(topic: 1, into: 2) == false)
        #expect(try fixture.topics.rename(topic: 1, to: "x") == false)
        #expect(try fixture.topics.topics(limit: 0).isEmpty)
        #expect(try fixture.topics.topic(ofSession: 99) == nil)
    }

    @Test func deletedContentNoLongerShapesTopics() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let secret = try fixture.store.record(
            text: "confidential merger acquisition negotiation terms", copiedAt: base)
        try fixture.topics.cluster(now: later)
        #expect(try fixture.topics.topics().first?.keywords.contains("merger") == true)
        try ItemActions(database: fixture.database).delete(contentID: secret.contentID)
        try fixture.topics.recluster(now: later)
        #expect(try fixture.topics.topics().allSatisfy { !$0.keywords.contains("merger") })
    }

    @Test func splittingTheOnlySessionOfATopicKeepsOneTopic() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fill(fixture, [swiftText])
        try fixture.topics.cluster(now: later)
        let session = try #require(try fixture.sessions.sessions().first)
        let old = try #require(try fixture.topics.topic(ofSession: session.id)?.topicID)
        let new = try #require(try fixture.topics.splitOff(sessionID: session.id))
        #expect(new != old)
        #expect(try fixture.topics.topics().map(\.id) == [new])
    }
    @Test func reusedSessionIDDoesNotInheritAnOldTopicOrBreakSplitOff() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let actions = ItemActions(database: fixture.database)
        _ = try fixture.store.record(text: swiftText[0], copiedAt: base)
        let doomed = try fixture.store.record(
            text: "merger acquisition negotiation terms",
            copiedAt: base.addingTimeInterval(10 * 3_600))
        try fixture.topics.cluster(now: later)
        let doomedTopic = try #require(
            try fixture.topics.topics().first {
                $0.keywords.contains("merger") || $0.label.contains("merger")
            }
        )
        try fixture.topics.rename(topic: doomedTopic.id, to: "Geheimprojekt")
        _ = try actions.delete(contentID: doomed.contentID, now: base)
        _ = try actions.purgeDeleted(olderThanDays: 0, now: later)

        _ = try fixture.store.record(
            text: kubeText[0], copiedAt: base.addingTimeInterval(20 * 3_600))
        try fixture.topics.cluster(now: later)
        #expect(try fixture.topics.topics().allSatisfy { $0.label != "Geheimprojekt" })

        let newest = try #require(try fixture.sessions.sessions().first)
        #expect(try fixture.topics.splitOff(sessionID: newest.id) != nil)
    }

    @Test func indexFollowsDeleteAndNewCopyWithTheSameCount() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let actions = ItemActions(database: fixture.database)
        let secret = try fixture.store.record(
            text: "confidential merger acquisition", copiedAt: base)
        _ = try fixture.store.record(text: swiftText[0], copiedAt: base.addingTimeInterval(60))
        try fixture.topics.cluster(now: later)
        _ = try actions.delete(contentID: secret.contentID, now: base)
        _ = try fixture.store.record(text: kubeText[0], copiedAt: base.addingTimeInterval(120))
        try fixture.topics.recluster(now: later)
        let words = try fixture.topics.topics().flatMap { $0.keywords + [$0.label] }
        #expect(words.allSatisfy { !$0.contains("merger") && !$0.contains("confidential") })
    }

    @Test func sessionsWithoutLiveItemsLeaveTheirTopic() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let only = try fixture.store.record(text: swiftText[0], copiedAt: base)
        try fixture.topics.cluster(now: later)
        #expect(try fixture.topics.topics().count == 1)
        _ = try ItemActions(database: fixture.database).delete(contentID: only.contentID, now: base)
        try fixture.topics.recluster(now: later)
        #expect(try fixture.topics.topics().isEmpty)
    }

    @Test func renamedTopicKeepsItsLabelWhenTheThresholdDrops() throws {
        let strict = try Fixture(configuration: TopicConfiguration(similarityThreshold: 0.6))
        defer { strict.temp.remove() }
        try fill(strict, [swiftText, kubeText, swiftText, kubeText])
        try strict.topics.cluster(now: later)
        let kube = try #require(
            try strict.topics.topics().first { $0.keywords.contains("kubernetes") })
        try strict.topics.rename(topic: kube.id, to: "Mein Thema")

        let loose = TopicService(
            database: strict.database, configuration: TopicConfiguration(similarityThreshold: 0.01))
        try loose.recluster(now: later)
        let topic = try #require(try loose.topics().first { $0.label == "Mein Thema" })
        #expect(topic.labelIsManual)
        #expect(topic.sessionCount == 2)
    }

    @Test func repoAndTicketSurviveManyHosts() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(
            text: "see https://github.com/acme/api/issues/1 about ABC-123", copiedAt: base)
        for index in 0..<25 {
            _ = try fixture.store.record(
                text: "note \(index)", copiedAt: base.addingTimeInterval(Double(index + 1)),
                context: CopyContext(url: "https://host\(index).example.com/page"))
        }
        try fixture.topics.cluster(now: later)
        let topic = try #require(try fixture.topics.topics().first)
        #expect(topic.label == "github.com/acme/api")
    }

    @Test func secretsNeverEnterTheIndex() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let key = "ghp_" + String(repeating: "aB3dE6gH9k", count: 3) + "xyz012"
        _ = try fixture.store.record(text: "deploy token \(key) kubernetes", copiedAt: base)
        try fixture.topics.cluster(now: later)
        let stored = try fixture.database.read { connection in
            try connection.query("SELECT term_counts FROM sessions") { $0.text(0) }
        }
        #expect(stored.allSatisfy { !$0.contains("aB3dE6gH9k") })
    }

    @Test func keysStraddlingTheIndexCutOffAreNotIndexed() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let key = "ghp_" + String(repeating: "aB3dE6gH9k", count: 3) + "xyz012"
        let text = String(repeating: "kubernetes ", count: 180) + key + " trailing"
        _ = try fixture.store.record(text: text, copiedAt: base)
        try fixture.topics.cluster(now: later)
        let stored = try fixture.database.read { connection in
            try connection.query("SELECT term_counts FROM sessions") { $0.text(0) }
        }
        #expect(stored.allSatisfy { !$0.contains("ab3de6gh9k") && !$0.contains("kubernetes") })
    }

    @Test func labelsFollowADeletionWithoutNewPlacements() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let secret = try fixture.store.record(
            text: "confidential merger acquisition negotiation", copiedAt: base)
        _ = try fixture.store.record(
            text: "confidential merger acquisition schedule", copiedAt: base.addingTimeInterval(60))
        try fixture.topics.cluster(now: later)
        #expect(try fixture.topics.topics().first?.keywords.contains("merger") == true)
        _ = try ItemActions(database: fixture.database).delete(
            contentID: secret.contentID, now: base)
        #expect(try fixture.topics.cluster(now: later) == 0)
        let keywords = try fixture.topics.topics().first?.keywords ?? []
        #expect(!keywords.contains("negotiation"))
    }
}

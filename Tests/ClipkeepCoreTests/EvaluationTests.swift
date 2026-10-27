import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct EvaluationTests {
    private static let evalDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("eval")

    private func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(
            type, from: Data(contentsOf: Self.evalDirectory.appendingPathComponent(name)))
    }

    // MARK: - The committed evaluation

    /// The regression guard: quality may not fall below the stored baseline.
    @Test func theSyntheticCorpusStaysAtOrAboveTheBaseline() throws {
        let corpus = try load(EvalCorpus.self, "synthetic-corpus.json")
        let gold = try load(GoldSet.self, "synthetic-gold.json")
        let baseline = try load(EvalBaseline.self, "baseline.json")
        let metrics = try EvalRunner.run(corpus: corpus, gold: gold)
        // Speed is only judged in release builds, like the other timing budgets.
        var checked = metrics
        if !PerformanceBudget.isEnforced { checked.p95LatencyMs = 0 }
        let regressions = baseline.regressions(of: checked)
        #expect(regressions.isEmpty, "\(regressions)")
        #expect(metrics.queryCount == gold.queries.count)
    }

    @Test func theCommittedDataHoldsNoSecretsOrPersonalData() throws {
        let corpus = try load(EvalCorpus.self, "synthetic-corpus.json")
        let detector = SecretDetector()
        for entry in corpus.entries {
            #expect(!detector.containsSecret(in: entry.text), "\(entry.id) looks like a secret")
            #expect(!entry.text.contains("@"), "\(entry.id) contains an address")
        }
        let urls = corpus.entries.flatMap { $0.text.split(separator: " ") }
            .filter { $0.hasPrefix("http") }
        #expect(urls.allSatisfy { $0.contains(".example.org/") })
    }

    // MARK: - Metrics

    @Test func aGoldSetIsRequired() throws {
        let corpus = try load(EvalCorpus.self, "synthetic-corpus.json")
        #expect(throws: EvalError.emptyGoldSet) {
            try EvalRunner.run(corpus: corpus, gold: GoldSet(queries: []))
        }
    }

    @Test func recallAndRankFollowThePositionOfTheTarget() throws {
        let entries = [
            EvalEntry(id: "a", text: "alpha shared text (a)", session: nil, minute: 0, app: nil),
            EvalEntry(id: "b", text: "beta shared text (b)", session: nil, minute: 1, app: nil),
            EvalEntry(id: "c", text: "gamma unique (c)", session: nil, minute: 2, app: nil),
        ]
        let gold = GoldSet(queries: [
            GoldQuery(query: "gamma", targetContains: "(c)"),
            // Newest first among equal matches: "beta" is ahead of "alpha".
            GoldQuery(query: "shared", targetContains: "(a)"),
            GoldQuery(query: "gamma", targetContains: "(zzz)"),
        ])
        let metrics = try EvalRunner.run(corpus: EvalCorpus(entries: entries), gold: gold)
        #expect(metrics.queryCount == 3)
        #expect(metrics.recallAt1 == 1.0 / 3)
        #expect(metrics.recallAt5 == 2.0 / 3)
        #expect(abs(metrics.meanReciprocalRank - (1 + 0.5 + 0) / 3) < 1e-9)
        #expect(metrics.sessionPairF1 == nil)
        #expect(metrics.medianLatencyMs >= 0)
    }

    @Test func sessionsAreScoredAgainstTheLabels() throws {
        // Two labelled sessions a long pause apart are reproduced exactly.
        var entries: [EvalEntry] = []
        for (index, minute) in [0.0, 2, 4, 120, 122].enumerated() {
            entries.append(
                EvalEntry(
                    id: "e\(index)", text: "entry number \(index) text",
                    session: index < 3 ? "s1" : "s2",
                    minute: minute, app: nil))
        }
        let gold = GoldSet(queries: [GoldQuery(query: "entry", targetContains: "number 0")])
        let metrics = try EvalRunner.run(corpus: EvalCorpus(entries: entries), gold: gold)
        #expect(metrics.sessionPairF1 == 1)
        #expect(metrics.sessionExactShare == 1)

        // The same events labelled as one session look split apart.
        let merged = entries.map {
            EvalEntry(id: $0.id, text: $0.text, session: "all", minute: $0.minute, app: nil)
        }
        let wrong = try EvalRunner.run(corpus: EvalCorpus(entries: merged), gold: gold)
        #expect((wrong.sessionPairF1 ?? 1) < 1)
        #expect(wrong.sessionExactShare == 0)
    }

    @Test func pairwiseScoresHandleOverMergingAndOverSplitting() {
        let labels = ["1": "a", "2": "a", "3": "b", "4": "b"]
        let merged = TestScores.scores(
            computed: ["1": "x", "2": "x", "3": "x", "4": "x"], labels: labels)
        // 6 pairs together; 2 are right: precision 1/3, recall 1.
        #expect(abs((merged.0 ?? 0) - 0.5) < 1e-9)
        #expect(merged.1 == 0)
        let split = TestScores.scores(
            computed: ["1": "p", "2": "q", "3": "r", "4": "s"], labels: labels)
        #expect(split.0 == 0)
        #expect(split.1 == 0)
        // Singletons only, computed apart: nothing to get wrong.
        let apart = TestScores.scores(
            computed: ["1": "p", "2": "q"], labels: ["1": "a", "2": "b"])
        #expect(apart.0 == 1)
        // An unlabelled event inside a computed session makes it inexact.
        let extra = TestScores.scores(
            computed: ["1": "p", "2": "p", "9": "p"], labels: ["1": "a", "2": "a"])
        #expect(extra.1 == 0)
        let single = TestScores.scores(computed: ["1": "p"], labels: ["1": "a"])
        #expect(single.0 == nil)
    }

    // MARK: - Baseline

    private func metrics(recall: Double, p95: Double = 1, f1: Double? = 1) -> EvalMetrics {
        EvalMetrics(
            queryCount: 10, recallAt1: recall, recallAt5: recall, recallAt10: recall,
            meanReciprocalRank: recall, medianLatencyMs: 1, p95LatencyMs: p95, sessionPairF1: f1,
            sessionExactShare: f1)
    }

    @Test func aDropBeyondTheToleranceIsARegression() {
        let baseline = EvalBaseline(metrics: metrics(recall: 0.8), tolerance: 0.02)
        #expect(baseline.regressions(of: metrics(recall: 0.79)).isEmpty)
        #expect(baseline.regressions(of: metrics(recall: 0.9)).isEmpty)
        let found = baseline.regressions(of: metrics(recall: 0.7))
        #expect(found.map(\.metric).contains("recall@1"))
        #expect(found.map(\.metric).contains("MRR"))
    }

    @Test func aShrunkenGoldSetIsARegression() {
        var fewer = metrics(recall: 0.8)
        fewer.queryCount = 5
        #expect(
            EvalBaseline(metrics: metrics(recall: 0.8)).regressions(of: fewer).map(\.metric) == [
                "queries"
            ])
    }

    @Test func slowQueriesAndMissingSessionScoresAreRegressions() {
        let baseline = EvalBaseline(metrics: metrics(recall: 0.8), maximumLatencyMs: 100)
        #expect(
            baseline.regressions(of: metrics(recall: 0.8, p95: 500)).map(\.metric) == [
                "p95 latency (ms)"
            ])
        let lost = baseline.regressions(of: metrics(recall: 0.8, f1: nil))
        #expect(lost.map(\.metric) == ["session pair F1", "session exact share"])
    }

    // MARK: - Report and import

    @Test func theReportListsEveryMetricAndRegression() {
        let text = metrics(recall: 0.5).report(
            title: "Test",
            regressions: [EvalRegression(metric: "recall@1", baseline: 0.8, actual: 0.5)])
        #expect(text.contains("| Recall@1 | 50.0 % |"))
        #expect(text.contains("| Time to result, p95 |"))
        #expect(text.contains("- recall@1: 0.500 (baseline 0.800)"))
        #expect(metrics(recall: 0.5).report(title: "T").contains("No regression"))
    }

    @Test func aTextFileCanBeEvaluatedWithoutSessionLabels() throws {
        let text =
            "first note about invoices\n---\nsecond note about travel plans\n---\nthird about cooking"
        let gold = GoldSet(queries: [GoldQuery(query: "travel", targetContains: "second note")])
        let metrics = try EvalRunner.run(importing: text, gold: gold)
        #expect(metrics.recallAt1 == 1)
        #expect(metrics.sessionPairF1 == nil)
    }

    /// A secret anywhere in a block drops the whole block, so the split mode decides how many
    /// gold targets survive the import.
    @Test func theSplitModeDecidesWhichTargetsSurviveTheImport() throws {
        let secret = "ghp_" + String(repeating: "aB3dE6gH9k", count: 3) + "xyz012"
        let text = """
            token \(secret)

            first note about invoices

            second note about travel plans
            ---
            third note about cooking
            """
        let gold = GoldSet(queries: [
            GoldQuery(query: "invoices", targetContains: "first note"),
            GoldQuery(query: "travel", targetContains: "second note"),
            GoldQuery(query: "cooking", targetContains: "third note"),
        ])
        // The separator line makes `automatic` cut at "---", so the block with the secret
        // takes the two notes after it with it.
        let automatic = try EvalRunner.run(importing: text, gold: gold)
        #expect(automatic.recallAt10 == 1.0 / 3)
        let blankLines = try EvalRunner.run(importing: text, gold: gold, mode: .blankLines)
        #expect(blankLines.recallAt10 == 1)
    }
}

enum TestScores {
    static func scores(computed: [String: String], labels: [String: String]) -> (Double?, Double?) {
        EvalRunner.sessionScores(computed: computed, labels: labels)
    }
}

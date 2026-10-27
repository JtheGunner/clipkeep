import Foundation

// MARK: - Inputs

/// One copy of the evaluation corpus. `session` is the ground truth for session grouping and
/// optional; entries of one session share the label.
public struct EvalEntry: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let session: String?
    /// Minutes since the start of the corpus.
    public let minute: Double
    public let app: String?
}

public struct EvalCorpus: Codable, Sendable, Equatable {
    public let entries: [EvalEntry]

    public init(entries: [EvalEntry]) {
        self.entries = entries
    }
}

/// A search the user would type and the entry they are after. The target is found by a
/// substring of its text, so a gold set also works on data that was imported from a file.
public struct GoldQuery: Codable, Sendable, Equatable {
    public let query: String
    public let targetContains: String
}

public struct GoldSet: Codable, Sendable, Equatable {
    public let queries: [GoldQuery]

    public init(queries: [GoldQuery]) {
        self.queries = queries
    }
}

// MARK: - Results

public struct EvalMetrics: Codable, Sendable, Equatable {
    public var queryCount: Int
    /// Share of queries whose target is among the first 1, 5 or 10 results.
    public var recallAt1: Double
    public var recallAt5: Double
    public var recallAt10: Double
    /// Mean of 1/rank, 0 for a target that was not found among the first `searchDepth`.
    public var meanReciprocalRank: Double
    /// Time from submitting the query to having the result list, in milliseconds.
    public var medianLatencyMs: Double
    public var p95LatencyMs: Double
    /// Pairwise F1 of the computed sessions against the labelled ones; nil without labels.
    public var sessionPairF1: Double?
    /// Share of labelled sessions that were reproduced exactly (same events, nothing more).
    public var sessionExactShare: Double?
}

public enum EvalError: Error, Equatable {
    case emptyGoldSet
}

public struct EvalRegression: Sendable, Equatable {
    public let metric: String
    public let baseline: Double
    public let actual: Double
}

/// Stored reference values. A quality metric may fall by at most `tolerance` (absolute);
/// latency must stay below `maximumLatencyMs`, a generous ceiling because speed depends on the
/// machine.
public struct EvalBaseline: Codable, Sendable, Equatable {
    public var metrics: EvalMetrics
    public var tolerance: Double
    public var maximumLatencyMs: Double

    public init(metrics: EvalMetrics, tolerance: Double = 0.02, maximumLatencyMs: Double = 250) {
        self.metrics = metrics
        self.tolerance = tolerance
        self.maximumLatencyMs = maximumLatencyMs
    }

    public func regressions(of actual: EvalMetrics) -> [EvalRegression] {
        var found: [EvalRegression] = []
        func check(_ name: String, _ base: Double?, _ now: Double?) {
            guard let base else { return }
            // A metric that existed in the baseline must not disappear.
            let value = now ?? -1
            if value < base - tolerance {
                found.append(EvalRegression(metric: name, baseline: base, actual: value))
            }
        }
        check("recall@1", metrics.recallAt1, actual.recallAt1)
        check("recall@5", metrics.recallAt5, actual.recallAt5)
        check("recall@10", metrics.recallAt10, actual.recallAt10)
        check("MRR", metrics.meanReciprocalRank, actual.meanReciprocalRank)
        check("session pair F1", metrics.sessionPairF1, actual.sessionPairF1)
        check("session exact share", metrics.sessionExactShare, actual.sessionExactShare)
        if actual.p95LatencyMs > maximumLatencyMs {
            found.append(
                EvalRegression(
                    metric: "p95 latency (ms)", baseline: maximumLatencyMs,
                    actual: actual.p95LatencyMs))
        }
        return found
    }
}

// MARK: - Running

/// Builds a throwaway encrypted database from a corpus (or an imported text file), runs the gold
/// queries through `SearchService` and compares the computed sessions with the labelled ones.
public enum EvalRunner {
    public static let searchDepth = 50

    public static func run(corpus: EvalCorpus, gold: GoldSet) throws -> EvalMetrics {
        guard !gold.queries.isEmpty else { throw EvalError.emptyGoldSet }
        return try withDatabase { database in
            let store = ContentStore(database: database)
            let origin = Date(timeIntervalSince1970: 1_700_000_000)
            var eventLabels: [String: String] = [:]
            for entry in corpus.entries.sorted(by: { $0.minute < $1.minute }) {
                let recorded = try store.record(
                    text: entry.text, copiedAt: origin.addingTimeInterval(entry.minute * 60),
                    context: CopyContext(appName: entry.app))
                if let label = entry.session { eventLabels[String(recorded.eventID)] = label }
            }
            var metrics = try searchMetrics(gold: gold, database: database)
            let sessions = try computedSessions(database: database)
            (metrics.sessionPairF1, metrics.sessionExactShare) = sessionScores(
                computed: sessions, labels: eventLabels)
            return metrics
        }
    }

    /// For data without ground truth for sessions, such as an imported text file.
    public static func run(
        importing text: String, gold: GoldSet, mode: SplitMode = .automatic
    ) throws -> EvalMetrics {
        guard !gold.queries.isEmpty else { throw EvalError.emptyGoldSet }
        return try withDatabase { database in
            _ = try TextImporter(database: database, secretSink: nil).run(
                text: text, mode: mode, source: "eval", endingAt: Date())
            return try searchMetrics(gold: gold, database: database)
        }
    }

    // MARK: - Search

    private static func searchMetrics(gold: GoldSet, database: Database) throws -> EvalMetrics {
        let search = SearchService(database: database)
        var ranks: [Int?] = []
        var latencies: [Double] = []
        for item in gold.queries {
            let started = DispatchTime.now().uptimeNanoseconds
            let hits = try search.search(item.query, filter: SearchFilter(limit: searchDepth))
            latencies.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
            ranks.append(hits.firstIndex { $0.text.contains(item.targetContains) }.map { $0 + 1 })
        }
        let count = Double(ranks.count)
        func recall(_ k: Int) -> Double {
            Double(ranks.filter { ($0 ?? .max) <= k }.count) / count
        }
        let reciprocal = ranks.map { $0.map { 1 / Double($0) } ?? 0 }.reduce(0, +) / count
        latencies.sort()
        return EvalMetrics(
            queryCount: ranks.count, recallAt1: recall(1), recallAt5: recall(5),
            recallAt10: recall(10), meanReciprocalRank: reciprocal,
            medianLatencyMs: percentile(latencies, 0.5), p95LatencyMs: percentile(latencies, 0.95),
            sessionPairF1: nil, sessionExactShare: nil)
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count) * fraction).rounded(.up)) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    // MARK: - Sessions

    private static func computedSessions(database: Database) throws -> [String: String] {
        try database.read { connection in
            Dictionary(
                uniqueKeysWithValues: try connection.query(
                    "SELECT id, session_id FROM copy_events WHERE session_id IS NOT NULL"
                ) { (String($0.int(0)), String($0.int(1))) })
        }
    }

    /// Pairwise F1 over all pairs of labelled events (same computed session vs same label) and
    /// the share of labelled sessions found exactly.
    static func sessionScores(computed: [String: String], labels: [String: String])
        -> (Double?, Double?)
    {
        let ids = labels.keys.sorted()
        guard ids.count > 1 else { return (nil, nil) }
        var truePositive = 0.0
        var falsePositive = 0.0
        var falseNegative = 0.0
        for first in 0..<ids.count {
            for second in (first + 1)..<ids.count {
                let sameLabel = labels[ids[first]] == labels[ids[second]]
                let sameComputed =
                    computed[ids[first]] != nil && computed[ids[first]] == computed[ids[second]]
                if sameLabel && sameComputed {
                    truePositive += 1
                } else if sameComputed {
                    falsePositive += 1
                } else if sameLabel {
                    falseNegative += 1
                }
            }
        }
        let precision = truePositive / max(truePositive + falsePositive, 1)
        let recall = truePositive / max(truePositive + falseNegative, 1)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)

        var byLabel: [String: Set<String>] = [:]
        var byComputed: [String: Set<String>] = [:]
        for id in ids {
            byLabel[labels[id] ?? "", default: []].insert(id)
            if let session = computed[id] { byComputed[session, default: []].insert(id) }
        }
        let computedSets = Set(byComputed.values)
        let exact = byLabel.values.filter { computedSets.contains($0) }.count
        return (f1, Double(exact) / Double(byLabel.count))
    }

    // MARK: - Database

    private static func withDatabase<T>(_ body: (Database) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let database = try Database(
            path: directory.appendingPathComponent("eval.db").path, key: key)
        try Schema.migrator.migrate(database)
        return try body(database)
    }
}

// MARK: - Report

extension EvalMetrics {
    /// A Markdown table of all metrics.
    public func report(title: String, regressions: [EvalRegression] = []) -> String {
        func percent(_ value: Double?) -> String {
            value.map { String(format: "%.1f %%", $0 * 100) } ?? "–"
        }
        var lines = [
            "# \(title)", "", "| Metric | Value |", "|---|---|",
            "| Queries | \(queryCount) |", "| Recall@1 | \(percent(recallAt1)) |",
            "| Recall@5 | \(percent(recallAt5)) |", "| Recall@10 | \(percent(recallAt10)) |",
            "| MRR | \(String(format: "%.3f", meanReciprocalRank)) |",
            "| Time to result, median | \(String(format: "%.1f", medianLatencyMs)) ms |",
            "| Time to result, p95 | \(String(format: "%.1f", p95LatencyMs)) ms |",
            "| Sessions, pairwise F1 | \(percent(sessionPairF1)) |",
            "| Sessions, exactly reproduced | \(percent(sessionExactShare)) |",
        ]
        if regressions.isEmpty {
            lines += ["", "No regression against the baseline."]
        } else {
            lines += ["", "**Regressions:**"]
            lines += regressions.map {
                "- \($0.metric): \(String(format: "%.3f", $0.actual)) (baseline \(String(format: "%.3f", $0.baseline)))"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

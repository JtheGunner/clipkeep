import Foundation

/// What one maintenance pass did. A step that failed is listed in `failures` by name; the
/// error is not kept because it could mention stored content.
public struct MaintenanceReport: Sendable, Equatable {
    public var sessionsRebuilt = false
    public var topicsPlaced = 0
    public var tierChanges = 0
    public var purged = 0
    public var indexed = 0
    public var failures: [String] = []
}

/// The periodic upkeep: sessions that are missing, topics for settled sessions, importance and
/// tiers that follow the clock, deleted items past their undo window and fingerprints of
/// older contents. Every step is independent: one that fails does not stop the others, and a
/// pass can be repeated at any time.
public struct MaintenanceService: Sendable {
    /// How long a deleted item can be restored.
    public static let undoWindowDays = 30.0
    private static let indexBatches = 50

    private let database: Database
    private let ranking: RankingConfiguration

    public init(database: Database, ranking: RankingConfiguration = .default) {
        self.database = database
        self.ranking = ranking
    }

    public func run(now: Date = Date()) -> MaintenanceReport {
        var report = MaintenanceReport()
        // Sessions first: topics and ranking read them.
        step("sessions", &report) { report in
            report.sessionsRebuilt = try SessionService(database: database).rebuildIfNeeded()
        }
        step("topics", &report) { report in
            report.topicsPlaced = try TopicService(database: database).cluster(now: now)
        }
        step("ranking", &report) { report in
            report.tierChanges = try RankingService(database: database, configuration: ranking)
                .refreshAll(now: now)
            _ = try RankingService(database: database, configuration: ranking)
                .applyRetention(now: now)
        }
        step("purge", &report) { report in
            report.purged = try ItemActions(database: database, configuration: ranking)
                .purgeDeleted(olderThanDays: Self.undoWindowDays, now: now)
        }
        step("index", &report) { report in
            let store = ContentStore(database: database, ranking: ranking)
            for _ in 0..<Self.indexBatches {
                let done = try store.indexUnfingerprintedContents()
                if done == 0 { break }
                report.indexed += done
            }
        }
        return report
    }

    private func step(
        _ name: String, _ report: inout MaintenanceReport,
        _ work: (inout MaintenanceReport) throws -> Void
    ) {
        do {
            try work(&report)
        } catch {
            report.failures.append(name)
        }
    }
}

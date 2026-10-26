import Foundation

/// Combined ranking settings.
public struct RankingConfiguration: Sendable, Equatable {
    public static let `default` = RankingConfiguration()

    public var weights: ScoringWeights
    public var policy: TierPolicy

    public init(weights: ScoringWeights = ScoringWeights(), policy: TierPolicy = TierPolicy()) {
        self.weights = weights
        self.policy = policy
    }
}

/// Keeps `importance` and `tier` of stored contents up to date and explains them. Use the same
/// `RankingConfiguration` as the `ContentStore`, otherwise stored scores and explanations differ.
/// Run `refreshAll` after upgrading and periodically so tiers and importance follow the clock.
/// Nothing is deleted unless `TierPolicy.archiveRetentionDays` was set explicitly.
public struct RankingService: Sendable {
    private static let recentCopiesConsidered = 100
    private let database: Database
    private let configuration: RankingConfiguration
    private let sessions: SessionConfiguration

    public init(
        database: Database, configuration: RankingConfiguration = .default,
        sessions: SessionConfiguration = .default
    ) {
        self.database = database
        self.configuration = configuration
        self.sessions = sessions
    }

    public func explain(contentID: Int64, now: Date = Date()) throws -> ScoreExplanation? {
        try database.read { connection in
            try Self.explanation(
                of: contentID, in: connection, configuration: configuration, now: now)
        }
    }

    /// Recomputes every content in batches; run it periodically so the tiers follow the clock.
    /// Returns how many contents changed tier.
    @discardableResult
    public func refreshAll(now: Date = Date(), batchSize: Int = 500) throws -> Int {
        var lastID: Int64 = 0
        var changed = 0
        while true {
            let ids = try database.read { connection in
                try connection.query(
                    "SELECT id FROM contents WHERE id > ? AND deleted_at IS NULL ORDER BY id LIMIT ?",
                    [.int(lastID), .int(Int64(max(batchSize, 1)))]
                ) { $0.int(0) }
            }
            guard let last = ids.last else { return changed }
            try database.write { connection in
                for id in ids {
                    if try Self.refresh(
                        contentID: id, in: connection, configuration: configuration, now: now)
                    {
                        changed += 1
                    }
                }
            }
            lastID = last
        }
    }

    /// Deletes contents whose last copy is older than the configured retention, except pinned or
    /// starred ones and those deleted by the user (left to `ItemActions.purgeDeleted`, so the
    /// undo window is never cut short).
    /// Does nothing unless `archiveRetentionDays` is set. The period is re-clamped here so even a
    /// policy mutated after creation can never reach into the hot or warm window. Deletes in
    /// small transactions so capture is never blocked for long. Returns the deleted count.
    @discardableResult
    public func applyRetention(now: Date = Date(), batchSize: Int = 500) throws -> Int {
        let policy = configuration.policy
        guard let configured = policy.archiveRetentionDays else { return 0 }
        let days = max(configured, policy.warmDays, policy.hotDays)
        let cutoff = now.addingTimeInterval(-days * 86_400).timeIntervalSince1970
        var deleted = 0
        while true {
            let count = try database.write { connection -> Int in
                let ids = try connection.query(
                    """
                    SELECT id FROM contents
                    WHERE pinned = 0 AND starred = 0 AND deleted_at IS NULL AND last_copied_at < ?
                    LIMIT ?
                    """,
                    [.double(cutoff), .int(Int64(max(batchSize, 1)))]
                ) { $0.int(0) }
                for id in ids {
                    try connection.execute("DELETE FROM contents WHERE id = ?", [.int(id)])
                }
                return ids.count
            }
            deleted += count
            if count == 0 {
                // Removed events can leave empty or mis-sized sessions; re-cutting repairs them.
                if deleted > 0 {
                    try SessionService(database: database, configuration: sessions).rebuild()
                }
                return deleted
            }
        }
    }

    /// Recomputes one content inside the caller's write transaction. Returns whether the tier changed.
    @discardableResult
    static func refresh(
        contentID: Int64, in connection: Connection, configuration: RankingConfiguration,
        now: Date
    ) throws -> Bool {
        guard
            let explanation = try explanation(
                of: contentID, in: connection, configuration: configuration, now: now)
        else { return false }
        let stored = try connection.query(
            "SELECT tier, importance FROM contents WHERE id = ?", [.int(contentID)]
        ) { (tier: $0.text(0), importance: $0.double(1)) }.first
        let tierChanged = stored?.tier != explanation.tier.rawValue
        if tierChanged || abs((stored?.importance ?? -1) - explanation.importance) > 1e-9 {
            try connection.execute(
                "UPDATE contents SET importance = ?, tier = ? WHERE id = ?",
                [
                    .double(explanation.importance), .text(explanation.tier.rawValue),
                    .int(contentID),
                ])
        }
        return tierChanged
    }

    private static func explanation(
        of contentID: Int64, in connection: Connection, configuration: RankingConfiguration,
        now: Date
    ) throws -> ScoreExplanation? {
        let header = try connection.query(
            "SELECT kind, length(text), pinned, starred, feedback FROM contents WHERE id = ?",
            [.int(contentID)]
        ) {
            (
                kind: $0.text(0), characters: Int($0.int(1)), pinned: $0.int(2) != 0,
                starred: $0.int(3) != 0, feedback: Int($0.int(4))
            )
        }
        guard let content = header.first else { return nil }

        let events = try connection.query(
            """
            SELECT copied_at, app_bundle_id FROM copy_events WHERE content_id = ?
            ORDER BY copied_at DESC, id DESC LIMIT ?
            """,
            [.int(contentID), .int(Int64(recentCopiesConsidered))]
        ) { (date: Date(timeIntervalSince1970: $0.double(0)), app: $0.optionalText(1)) }
        let count =
            try connection.query(
                "SELECT count(*) FROM copy_events WHERE content_id = ?", [.int(contentID)]
            ) { Int($0.int(0)) }.first ?? 0

        let input = ScoreInput(
            copyDates: events.map(\.date), copyCount: count,
            kind: ContentKind(rawValue: content.kind) ?? .text, characterCount: content.characters,
            latestAppBundleID: events.first?.app, isPinned: content.pinned,
            isStarred: content.starred, feedbackSteps: content.feedback)
        return Scorer.explain(
            input, weights: configuration.weights, policy: configuration.policy, now: now)
    }
}

import Foundation

public enum FeedbackAction: String, Sendable, Equatable, CaseIterable {
    case pin, unpin, star, unstar, delete, restore, recopy, more, less
}

/// One recorded user action with the item's features as they were just before the action
/// (importance, copy count), so a later model sees the state the user decided in.
/// `recopy` marks a deleted text that came back because it was copied again.
/// Events of a purged item keep their features but lose the link to it.
public struct FeedbackEvent: Sendable, Equatable {
    public let id: Int64
    public let contentID: Int64?
    public let action: FeedbackAction
    public let createdAt: Date
    public let kind: String
    public let appBundleID: String?
    public let importance: Double
    public let copyCount: Int
}

/// Explicit user control over importance (per item: "more/less like this" does not touch similar
/// items, that is left to a later learning model): pin, star, delete with undo, more/less like this.
/// Every action is stored as a `FeedbackEvent`. Use the same `RankingConfiguration` as the
/// `ContentStore` so stored scores stay consistent.
public struct ItemActions: Sendable {
    /// Net "more/less like this" steps are clamped to ±this value.
    public static let feedbackLimit = 3

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

    /// Each returns `false` when the item does not exist. An action that changes nothing (pinning
    /// a pinned item, deleting a deleted one, a feedback step at the limit) returns `true` but is
    /// not logged, so repeated clicks do not inflate the signal.
    @discardableResult
    public func setPinned(_ isPinned: Bool, contentID: Int64, now: Date = Date()) throws -> Bool {
        try apply(isPinned ? .pin : .unpin, to: contentID, now: now) {
            try $0.execute(
                "UPDATE contents SET pinned = ?1 WHERE id = ?2 AND pinned != ?1",
                [.int(isPinned ? 1 : 0), .int(contentID)])
        }
    }

    @discardableResult
    public func setStarred(_ isStarred: Bool, contentID: Int64, now: Date = Date()) throws -> Bool {
        try apply(isStarred ? .star : .unstar, to: contentID, now: now) {
            try $0.execute(
                "UPDATE contents SET starred = ?1 WHERE id = ?2 AND starred != ?1",
                [.int(isStarred ? 1 : 0), .int(contentID)])
        }
    }

    /// Hides the item from search and views. Undo with `restore`; `purgeDeleted` removes it for good.
    @discardableResult
    public func delete(contentID: Int64, now: Date = Date()) throws -> Bool {
        try apply(.delete, to: contentID, now: now) {
            try $0.execute(
                "UPDATE contents SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                [SQLValue(now), .int(contentID)])
        }
    }

    @discardableResult
    public func restore(contentID: Int64, now: Date = Date()) throws -> Bool {
        try apply(.restore, to: contentID, now: now) {
            try $0.execute(
                "UPDATE contents SET deleted_at = NULL WHERE id = ? AND deleted_at IS NOT NULL",
                [.int(contentID)])
        }
    }

    /// "More like this": raises the item's score by one step (up to `feedbackLimit`).
    @discardableResult
    public func moreLikeThis(contentID: Int64, now: Date = Date()) throws -> Bool {
        try adjustFeedback(by: 1, action: .more, contentID: contentID, now: now)
    }

    /// "Less like this": lowers the item's score by one step (down to `-feedbackLimit`).
    @discardableResult
    public func lessLikeThis(contentID: Int64, now: Date = Date()) throws -> Bool {
        try adjustFeedback(by: -1, action: .less, contentID: contentID, now: now)
    }

    /// Permanently removes items deleted at least `days` ago. The caller picks the undo window.
    @discardableResult
    public func purgeDeleted(olderThanDays days: Double, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-max(days, 0) * 86_400).timeIntervalSince1970
        let purged = try database.write { connection -> Int in
            let ids = try connection.query(
                "SELECT id FROM contents WHERE deleted_at IS NOT NULL AND deleted_at <= ?",
                [.double(cutoff)]
            ) { $0.int(0) }
            for id in ids {
                try connection.execute("DELETE FROM contents WHERE id = ?", [.int(id)])
            }
            return ids.count
        }
        // Removed events can leave empty or mis-sized sessions; re-cutting repairs them.
        if purged > 0 { try SessionService(database: database, configuration: sessions).rebuild() }
        return purged
    }

    public func events(contentID: Int64) throws -> [FeedbackEvent] {
        try database.read { connection in
            try connection.query(
                """
                SELECT id, content_id, action, created_at, kind, app_bundle_id, importance, copy_count
                FROM feedback_events WHERE content_id = ? ORDER BY id
                """,
                [.int(contentID)]
            ) { row in
                FeedbackAction(rawValue: row.text(2)).map {
                    FeedbackEvent(
                        id: row.int(0), contentID: row.isNull(1) ? nil : row.int(1), action: $0,
                        createdAt: Date(timeIntervalSince1970: row.double(3)), kind: row.text(4),
                        appBundleID: row.optionalText(5), importance: row.double(6),
                        copyCount: Int(row.int(7)))
                }
            }.compactMap { $0 }
        }
    }

    private func adjustFeedback(
        by delta: Int, action: FeedbackAction, contentID: Int64, now: Date
    ) throws -> Bool {
        try apply(action, to: contentID, now: now) {
            try $0.execute(
                """
                UPDATE contents SET feedback = max(?1, min(?2, feedback + ?3))
                WHERE id = ?4 AND feedback != max(?1, min(?2, feedback + ?3))
                """,
                [
                    .int(Int64(-Self.feedbackLimit)), .int(Int64(Self.feedbackLimit)),
                    .int(Int64(delta)), .int(contentID),
                ])
        }
    }

    /// Features of an item at one moment, stored with each event.
    struct Snapshot {
        let kind: String
        let appBundleID: String?
        let importance: Double
        let copyCount: Int
    }

    static func snapshot(of contentID: Int64, in connection: Connection) throws -> Snapshot? {
        try connection.query(
            """
            SELECT c.kind,
                (SELECT app_bundle_id FROM copy_events WHERE content_id = c.id
                    ORDER BY copied_at DESC, id DESC LIMIT 1),
                c.importance, (SELECT count(*) FROM copy_events WHERE content_id = c.id)
            FROM contents c WHERE c.id = ?
            """,
            [.int(contentID)]
        ) {
            Snapshot(
                kind: $0.text(0), appBundleID: $0.optionalText(1), importance: $0.double(2),
                copyCount: Int($0.int(3)))
        }.first
    }

    static func log(
        _ action: FeedbackAction, contentID: Int64, snapshot: Snapshot, now: Date,
        in connection: Connection
    ) throws {
        try connection.execute(
            """
            INSERT INTO feedback_events
                (content_id, action, created_at, kind, app_bundle_id, importance, copy_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(contentID), .text(action.rawValue), SQLValue(now), .text(snapshot.kind),
                SQLValue(snapshot.appBundleID), .double(snapshot.importance),
                .int(Int64(snapshot.copyCount)),
            ])
    }

    /// Runs `change`, then rescores and logs in one transaction. Logs only if `change` modified a row.
    private func apply(
        _ action: FeedbackAction, to contentID: Int64, now: Date,
        change: (Connection) throws -> Void
    ) throws -> Bool {
        try database.write { connection in
            guard let before = try Self.snapshot(of: contentID, in: connection) else {
                return false
            }
            try change(connection)
            guard connection.changedRowCount > 0 else { return true }
            try RankingService.refresh(
                contentID: contentID, in: connection, configuration: configuration, now: now)
            try Self.log(action, contentID: contentID, snapshot: before, now: now, in: connection)
            if action == .delete || action == .restore {
                try SessionService.recut(
                    ofContent: contentID, in: connection, configuration: sessions)
            }
            return true
        }
    }
}

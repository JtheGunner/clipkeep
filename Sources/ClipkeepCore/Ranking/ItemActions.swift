import Foundation

public enum FeedbackAction: String, Sendable, Equatable, CaseIterable {
    case pin, unpin, star, unstar, delete, restore, more, less
}

/// One recorded user action with the item's features at that moment.
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

/// Explicit user control over importance: pin, star, delete with undo, more/less like this.
/// Every action is stored as a `FeedbackEvent`. Use the same `RankingConfiguration` as the
/// `ContentStore` so stored scores stay consistent.
public struct ItemActions: Sendable {
    /// Net "more/less like this" steps are clamped to ±this value.
    public static let feedbackLimit = 3

    private let database: Database
    private let configuration: RankingConfiguration

    public init(database: Database, configuration: RankingConfiguration = .default) {
        self.database = database
        self.configuration = configuration
    }

    /// Each returns `false` when the item does not exist (nothing is recorded then).
    @discardableResult
    public func setPinned(_ isPinned: Bool, contentID: Int64, now: Date = Date()) throws -> Bool {
        try apply(isPinned ? .pin : .unpin, to: contentID, now: now) {
            try $0.execute(
                "UPDATE contents SET pinned = ? WHERE id = ?",
                [.int(isPinned ? 1 : 0), .int(contentID)])
        }
    }

    @discardableResult
    public func setStarred(_ isStarred: Bool, contentID: Int64, now: Date = Date()) throws -> Bool {
        try apply(isStarred ? .star : .unstar, to: contentID, now: now) {
            try $0.execute(
                "UPDATE contents SET starred = ? WHERE id = ?",
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
                "UPDATE contents SET deleted_at = NULL WHERE id = ?", [.int(contentID)])
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
        return try database.write { connection in
            let ids = try connection.query(
                "SELECT id FROM contents WHERE deleted_at IS NOT NULL AND deleted_at <= ?",
                [.double(cutoff)]
            ) { $0.int(0) }
            for id in ids {
                try connection.execute("DELETE FROM contents WHERE id = ?", [.int(id)])
            }
            return ids.count
        }
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
                "UPDATE contents SET feedback = max(?, min(?, feedback + ?)) WHERE id = ?",
                [
                    .int(Int64(-Self.feedbackLimit)), .int(Int64(Self.feedbackLimit)),
                    .int(Int64(delta)), .int(contentID),
                ])
        }
    }

    /// Runs `change`, rescoring and logging in one transaction.
    private func apply(
        _ action: FeedbackAction, to contentID: Int64, now: Date,
        change: (Connection) throws -> Void
    ) throws -> Bool {
        try database.write { connection in
            let exists = try connection.query(
                "SELECT 1 FROM contents WHERE id = ?", [.int(contentID)]
            ) { _ in 1 }
            guard !exists.isEmpty else { return false }
            try change(connection)
            try RankingService.refresh(
                contentID: contentID, in: connection, configuration: configuration, now: now)
            try connection.execute(
                """
                INSERT INTO feedback_events
                    (content_id, action, created_at, kind, app_bundle_id, importance, copy_count)
                SELECT c.id, ?, ?, c.kind,
                    (SELECT app_bundle_id FROM copy_events WHERE content_id = c.id
                        ORDER BY copied_at DESC, id DESC LIMIT 1),
                    c.importance, (SELECT count(*) FROM copy_events WHERE content_id = c.id)
                FROM contents c WHERE c.id = ?
                """,
                [.text(action.rawValue), SQLValue(now), .int(contentID)])
            return true
        }
    }
}

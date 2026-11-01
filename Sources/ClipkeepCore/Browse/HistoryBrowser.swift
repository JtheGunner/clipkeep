import Foundation

/// One copy inside a session, as the entry list shows it. The text is cut to `previewLength`;
/// `HistoryBrowser.detail` loads the whole text.
public struct SessionEntry: Sendable, Equatable {
    public let eventID: Int64
    public let contentID: Int64
    public let preview: String
    public let kind: String
    public let copiedAt: Date
    public let appName: String?
    public let windowTitle: String?
    public let url: String?
    public let isPinned: Bool
    public let isStarred: Bool
}

public struct EntryOccurrence: Sendable, Equatable {
    public let copiedAt: Date
    public let appName: String?
    public let windowTitle: String?
    public let url: String?
    public let sessionID: Int64?
}

/// Everything the detail pane shows about one stored text.
public struct EntryDetail: Sendable, Equatable {
    public let contentID: Int64
    public let text: String
    public let kind: String
    public let isPinned: Bool
    public let isStarred: Bool
    public let occurrenceCount: Int
    /// Newest first, at most `HistoryBrowser.occurrenceLimit`.
    public let occurrences: [EntryOccurrence]
    public let entities: [SessionSummary.EntityShare]
    public let score: ScoreExplanation?
}

/// Read side of the history window: sessions by day or topic, the entries of a session and the
/// detail of one entry. Every list is paged by a cursor, so a window over 100 000 entries only
/// ever holds the pages the user scrolled to.
public struct HistoryBrowser: Sendable {
    public static let previewLength = 400
    public static let occurrenceLimit = 20
    private static let topicScanLimit = 100_000

    private let database: Database
    private let sessions: SessionService
    private let topics: TopicService
    private let ranking: RankingService

    /// A cheap fingerprint of what the history shows. It changes when a copy is recorded, an entry
    /// is deleted or restored, or a parked secret is restored, so an open window can tell it is out of date
    /// without loading the lists. It reads index-backed counts only, never entry text.
    public func changeToken() throws -> String {
        try database.read { connection in
            try connection.query(
                """
                SELECT
                    (SELECT count(*) FROM contents),
                    (SELECT count(*) FROM contents WHERE deleted_at IS NOT NULL),
                    (SELECT coalesce(max(id), 0) FROM contents),
                    (SELECT count(*) FROM copy_events),
                    (SELECT coalesce(max(id), 0) FROM copy_events),
                    (SELECT count(*) FROM parked_secrets),
                    (SELECT coalesce(sum(id), 0) FROM parked_secrets),
                    (SELECT count(*) FROM parked_secrets WHERE state = 'parked')
                """
            ) { row in (0..<8).map { String(row.int(Int32($0))) }.joined(separator: ":") }
            .first ?? ""
        }
    }

    public init(
        database: Database, ranking: RankingConfiguration = .default,
        sessions: SessionConfiguration = .default
    ) {
        self.database = database
        self.sessions = SessionService(database: database, configuration: sessions)
        self.topics = TopicService(database: database)
        self.ranking = RankingService(
            database: database, configuration: ranking, sessions: sessions)
    }

    // MARK: - Sessions

    /// Newest first. Pass the last session of the previous page as `after`. With `entity`, only
    /// sessions in which an item with that entity was copied.
    public func sessions(
        limit: Int = 50, after: SessionSummary? = nil, entity: EntityFilter? = nil
    ) throws -> [SessionSummary] {
        guard let entity else { return try sessions.sessions(limit: limit, after: after) }
        guard limit > 0 else { return [] }
        let cursor = after.map { ($0.startedAt.timeIntervalSince1970, $0.id) } ?? (.infinity, .max)
        return try database.read { connection in
            try connection.query(
                """
                SELECT \(SessionService.summaryColumns) FROM sessions
                WHERE event_count > 0 AND (started_at, id) < (?, ?) AND id IN (
                    SELECT e.session_id FROM entities n
                    JOIN contents k ON k.id = n.content_id AND k.deleted_at IS NULL
                    JOIN copy_events e ON e.content_id = n.content_id
                    WHERE n.kind = ? AND n.value = ? AND e.session_id IS NOT NULL)
                ORDER BY started_at DESC, id DESC LIMIT ?
                """,
                [
                    .double(cursor.0), .int(cursor.1), .text(entity.kind), .text(entity.value),
                    .int(Int64(limit)),
                ], map: SessionService.summary)
        }
    }

    /// The sessions of a topic, newest first; with `entity` only those that have it.
    public func sessions(inTopic topicID: Int64, entity: EntityFilter? = nil) throws
        -> [SessionSummary]
    {
        guard let entity else {
            return try sessions.sessions(ids: topics.sessionIDs(inTopic: topicID))
        }
        let ids: [Int64] = try database.read { connection in
            try connection.query(
                """
                SELECT id FROM sessions WHERE topic_id = ? AND id IN (
                    SELECT e.session_id FROM entities n
                    JOIN contents k ON k.id = n.content_id AND k.deleted_at IS NULL
                    JOIN copy_events e ON e.content_id = n.content_id
                    WHERE n.kind = ? AND n.value = ? AND e.session_id IS NOT NULL)
                """,
                [.int(topicID), .text(entity.kind), .text(entity.value)]
            ) { $0.int(0) }
        }
        return try sessions.sessions(ids: ids)
    }

    /// Topics that have a session with the entity (all topics without a filter).
    public func topics(limit: Int = 100, entity: EntityFilter? = nil) throws -> [TopicSummary] {
        let all = try topics.topics(limit: entity == nil ? limit : Self.topicScanLimit)
        guard let entity else { return all }
        let ids: Set<Int64> = try database.read { connection in
            Set(
                try connection.query(
                    """
                    SELECT DISTINCT s.topic_id FROM entities n
                    JOIN contents k ON k.id = n.content_id AND k.deleted_at IS NULL
                    JOIN copy_events e ON e.content_id = n.content_id
                    JOIN sessions s ON s.id = e.session_id
                    WHERE n.kind = ? AND n.value = ? AND s.topic_id IS NOT NULL
                    """,
                    [.text(entity.kind), .text(entity.value)]
                ) { $0.int(0) })
        }
        return Array(all.filter { ids.contains($0.id) }.prefix(max(limit, 0)))
    }

    /// The topic a session belongs to and why, nil for a session without one.
    public func topicInfo(ofSession sessionID: Int64) throws -> SessionTopicInfo? {
        try database.read { connection in
            try connection.query(
                """
                SELECT t.id, t.label, t.keywords, s.topic_reason, s.topic_locked
                FROM sessions s JOIN topics t ON t.id = s.topic_id WHERE s.id = ?
                """,
                [.int(sessionID)]
            ) { row in
                SessionTopicInfo(
                    topicID: row.int(0), label: row.text(1),
                    keywords: SessionService.decode(row.text(2)), reason: row.text(3),
                    isLocked: row.int(4) != 0)
            }.first
        }
    }

    /// The most common entities, for the filter menu. Placeholders of parked secrets and deleted
    /// items do not count.
    public func entityChoices(limit: Int = 30) throws -> [EntityChoice] {
        guard limit > 0 else { return [] }
        return try database.read { connection in
            try connection.query(
                """
                SELECT n.kind, n.value, count(*) AS uses FROM entities n
                JOIN contents c ON c.id = n.content_id
                WHERE c.deleted_at IS NULL AND c.kind != 'secret'
                GROUP BY n.kind, n.value ORDER BY uses DESC, n.value LIMIT ?
                """,
                [.int(Int64(limit))]
            ) {
                EntityChoice(
                    filter: EntityFilter(kind: $0.text(0), value: $0.text(1)), uses: Int($0.int(2)))
            }
        }
    }

    // MARK: - Entries

    /// The copies of a session in the order they happened. Pass the last entry of the previous
    /// page as `after`. Deleted items are left out.
    public func entries(
        inSession sessionID: Int64, limit: Int = 100, after: SessionEntry? = nil
    ) throws -> [SessionEntry] {
        guard limit > 0 else { return [] }
        let cursor =
            after.map { ($0.copiedAt.timeIntervalSince1970, $0.eventID) } ?? (-.infinity, Int64.min)
        return try database.read { connection in
            try connection.query(
                """
                SELECT e.id, c.id, substr(c.text, 1, \(Self.previewLength)), c.kind, e.copied_at,
                    e.app_name, e.window_title, e.url, c.pinned, c.starred
                FROM copy_events e JOIN contents c ON c.id = e.content_id
                WHERE e.session_id = ? AND c.deleted_at IS NULL AND (e.copied_at, e.id) > (?, ?)
                ORDER BY e.copied_at, e.id LIMIT ?
                """,
                [.int(sessionID), .double(cursor.0), .int(cursor.1), .int(Int64(limit))]
            ) { row in
                SessionEntry(
                    eventID: row.int(0), contentID: row.int(1), preview: row.text(2),
                    kind: row.text(3), copiedAt: Date(timeIntervalSince1970: row.double(4)),
                    appName: row.optionalText(5), windowTitle: row.optionalText(6),
                    url: row.optionalText(7), isPinned: row.int(8) != 0, isStarred: row.int(9) != 0)
            }
        }
    }

    // MARK: - Detail

    public func detail(contentID: Int64, now: Date = Date()) throws -> EntryDetail? {
        guard let stored = try database.read({ try Self.load(contentID, in: $0) }) else {
            return nil
        }
        return EntryDetail(
            contentID: contentID, text: stored.text, kind: stored.kind, isPinned: stored.isPinned,
            isStarred: stored.isStarred, occurrenceCount: stored.occurrenceCount,
            occurrences: stored.occurrences, entities: stored.entities,
            score: try ranking.explain(contentID: contentID, now: now))
    }

    private struct StoredDetail {
        let text: String
        let kind: String
        let isPinned: Bool
        let isStarred: Bool
        let occurrenceCount: Int
        let occurrences: [EntryOccurrence]
        let entities: [SessionSummary.EntityShare]
    }

    private static func load(_ contentID: Int64, in connection: Connection) throws -> StoredDetail?
    {
        let rows = try connection.query(
            "SELECT text, kind, pinned, starred FROM contents WHERE id = ? AND deleted_at IS NULL",
            [.int(contentID)]
        ) { ($0.text(0), $0.text(1), $0.int(2) != 0, $0.int(3) != 0) }
        guard let content = rows.first else { return nil }
        let count =
            try connection.query(
                "SELECT count(*) FROM copy_events WHERE content_id = ?", [.int(contentID)]
            ) { Int($0.int(0)) }.first ?? 0
        let occurrences = try connection.query(
            """
            SELECT copied_at, app_name, window_title, url, session_id FROM copy_events
            WHERE content_id = ? ORDER BY copied_at DESC, id DESC LIMIT ?
            """,
            [.int(contentID), .int(Int64(occurrenceLimit))]
        ) { row in
            EntryOccurrence(
                copiedAt: Date(timeIntervalSince1970: row.double(0)),
                appName: row.optionalText(1), windowTitle: row.optionalText(2),
                url: row.optionalText(3), sessionID: row.isNull(4) ? nil : row.int(4))
        }
        let entities = try connection.query(
            "SELECT kind, value FROM entities WHERE content_id = ? ORDER BY kind, value",
            [.int(contentID)]
        ) { SessionSummary.EntityShare(kind: $0.text(0), value: $0.text(1), count: 1) }
        return StoredDetail(
            text: content.0, kind: content.1, isPinned: content.2, isStarred: content.3,
            occurrenceCount: count, occurrences: occurrences, entities: entities)
    }
}

/// A specific entity, such as a repository or a domain.
public struct EntityFilter: Sendable, Equatable, Hashable {
    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct EntityChoice: Sendable, Equatable {
    public let filter: EntityFilter
    public let uses: Int
}

public struct SessionTopicInfo: Sendable, Equatable {
    public let topicID: Int64
    public let label: String
    public let keywords: [String]
    public let reason: String
    /// True when the user placed the session by hand.
    public let isLocked: Bool
}

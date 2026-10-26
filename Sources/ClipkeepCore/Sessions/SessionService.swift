import Foundation

public struct SessionSummary: Sendable, Equatable {
    public struct AppShare: Sendable, Equatable, Codable {
        public let bundleID: String
        public let count: Int
    }

    public struct EntityShare: Sendable, Equatable, Codable {
        public let kind: String
        public let value: String
        public let count: Int
    }

    public let id: Int64
    public let startedAt: Date
    public let endedAt: Date
    public let eventCount: Int
    public let start: SessionStart
    public let dominantApps: [AppShare]
    public let topEntities: [EntityShare]
    public let topicID: Int64?

    /// Why the session starts here, as a sentence for the user.
    public var explanation: String { start.explanation }
}

/// Groups copy events into sessions and keeps the grouping current.
///
/// Sessions are identified by their first event, so recomputing never changes ids or topic links
/// of sessions whose start did not move. `rebuild` is idempotent.
public struct SessionService: Sendable {
    private static let topApps = 3
    private static let topEntities = 5
    private static let entityKinds = ["repo", "domain", "ticket"]
    private static let chunk = 500
    static let dirtyKey = "sessions_dirty"

    private let database: Database
    private let configuration: SessionConfiguration

    public init(database: Database, configuration: SessionConfiguration = .default) {
        self.database = database
        self.configuration = configuration
    }

    /// Recomputes every session from the stored events. Returns the number of sessions.
    @discardableResult
    public func rebuild() throws -> Int {
        try database.write { connection in
            let count = try Self.resegment(
                from: nil, until: nil, preserveFirstStart: false, in: connection,
                configuration: configuration)
            try connection.execute("DELETE FROM settings WHERE key = ?", [.text(Self.dirtyKey)])
            return count
        }
    }

    /// Rebuilds when events have no session yet (after an upgrade or a bulk import) or when an
    /// incremental assignment failed earlier. Call it at startup. Returns whether it rebuilt.
    @discardableResult
    public func rebuildIfNeeded() throws -> Bool {
        let needed = try database.read { connection in
            let flagged = try connection.query(
                "SELECT 1 FROM settings WHERE key = ?", [.text(Self.dirtyKey)]
            ) { _ in 1 }
            let unassigned = try connection.query(
                "SELECT 1 FROM copy_events WHERE session_id IS NULL LIMIT 1"
            ) { _ in 1 }
            return !flagged.isEmpty || !unassigned.isEmpty
        }
        guard needed else { return false }
        try rebuild()
        return true
    }

    /// Newest first. Pass the last session of the previous page as `after` to get the next page.
    public func sessions(limit: Int = 50, after: SessionSummary? = nil) throws -> [SessionSummary] {
        guard limit > 0 else { return [] }
        let cursor =
            after.map { ($0.startedAt.timeIntervalSince1970, $0.id) } ?? (
                Double.infinity, Int64.max
            )
        return try database.read { connection in
            try connection.query(
                """
                SELECT id, started_at, ended_at, event_count, start_reason, start_detail,
                    dominant_apps, top_entities, topic_id
                FROM sessions WHERE event_count > 0 AND (started_at, id) < (?, ?)
                ORDER BY started_at DESC, id DESC LIMIT ?
                """,
                [.double(cursor.0), .int(cursor.1), .int(Int64(limit))]
            ) { row in
                SessionSummary(
                    id: row.int(0), startedAt: Date(timeIntervalSince1970: row.double(1)),
                    endedAt: Date(timeIntervalSince1970: row.double(2)),
                    eventCount: Int(row.int(3)),
                    start: SessionStart(code: row.text(4), detail: row.text(5)) ?? .first,
                    dominantApps: Self.decode(row.text(6)), topEntities: Self.decode(row.text(7)),
                    topicID: row.isNull(8) ? nil : row.int(8))
            }
        }
    }

    /// Assigns a freshly inserted event, inside the caller's transaction.
    ///
    /// - A pause above the gap threshold opens a one-event session directly.
    /// - Otherwise only the newest session (the "tail") is re-cut; its stored start reason is kept
    ///   because that cut was decided by events before the tail.
    /// - An event that is not the newest, or whose predecessor has no session yet, triggers a full
    ///   rebuild, since it can change cuts anywhere around it.
    static func assign(
        eventID: Int64, in connection: Connection, configuration: SessionConfiguration
    ) throws {
        guard
            let event = try connection.query(
                "SELECT copied_at FROM copy_events WHERE id = ?", [.int(eventID)]
            ) { $0.double(0) }.first
        else { return }

        let isLate = try !connection.query(
            "SELECT 1 FROM copy_events WHERE (copied_at, id) > (?, ?) LIMIT 1",
            [.double(event), .int(eventID)]
        ) { _ in 1 }.isEmpty
        let prior = try connection.query(
            """
            SELECT copied_at, session_id FROM copy_events WHERE (copied_at, id) < (?, ?)
            ORDER BY copied_at DESC, id DESC LIMIT 1
            """,
            [.double(event), .int(eventID)]
        ) { (time: $0.double(0), hasSession: !$0.isNull(1)) }.first

        guard !isLate, let prior, prior.hasSession else {
            if prior == nil, !isLate {
                try insertSession(
                    eventID: eventID, time: event, start: .first, in: connection)
            } else {
                try resegment(
                    from: nil, until: nil, preserveFirstStart: false, in: connection,
                    configuration: configuration)
            }
            return
        }

        let pause = event - prior.time
        if pause > configuration.gap {
            try insertSession(
                eventID: eventID, time: event, start: .gap(minutes: Int(pause / 60)),
                in: connection)
            return
        }
        // Re-cut from the last pause-based boundary: unlike an app switch or a context switch,
        // it depends on timestamps only, and a context switch decided here may be confirmed
        // by copies that arrive after an app switch.
        guard
            let tail = try connection.query(
                """
                SELECT started_at, first_event_id FROM sessions
                ORDER BY started_at DESC, first_event_id DESC LIMIT 1
                """
            ) { (time: $0.double(0), id: $0.int(1)) }.first,
            let anchor = try anchor(atOrBefore: tail, in: connection)
        else {
            try resegment(
                from: nil, until: nil, preserveFirstStart: false, in: connection,
                configuration: configuration)
            return
        }
        try resegment(
            from: anchor, until: nil, preserveFirstStart: true, in: connection,
            configuration: configuration)
    }

    typealias Key = (time: Double, id: Int64)

    /// The newest session at or before `key` that starts with a pause (or is the very first one).
    /// The segmenter's state is reset there and its lookahead never crosses a pause, so cuts
    /// before it cannot depend on later events.
    private static func anchor(atOrBefore key: Key, in connection: Connection) throws -> Key? {
        try connection.query(
            """
            SELECT started_at, first_event_id FROM sessions
            WHERE start_reason IN ('gap', 'first') AND (started_at, first_event_id) <= (?, ?)
            ORDER BY started_at DESC, first_event_id DESC LIMIT 1
            """,
            [.double(key.time), .int(key.id)]
        ) { (time: $0.double(0), id: $0.int(1)) }.first
    }

    /// The oldest pause-based session strictly after `key`, if any.
    private static func anchor(after key: Key, in connection: Connection) throws -> Key? {
        try connection.query(
            """
            SELECT started_at, first_event_id FROM sessions
            WHERE start_reason IN ('gap', 'first') AND (started_at, first_event_id) > (?, ?)
            ORDER BY started_at, first_event_id LIMIT 1
            """,
            [.double(key.time), .int(key.id)]
        ) { (time: $0.double(0), id: $0.int(1)) }.first
    }

    private static func insertSession(
        eventID: Int64, time: Double, start: SessionStart, in connection: Connection
    ) throws {
        try connection.execute(
            """
            INSERT INTO sessions
                (started_at, ended_at, first_event_id, event_count, start_reason, start_detail)
            VALUES (?1, ?1, ?2, 1, ?3, ?4)
            """,
            [.double(time), .int(eventID), .text(start.code), .text(start.detail)])
        let sessionID = connection.lastInsertRowID
        try connection.execute(
            "UPDATE copy_events SET session_id = ? WHERE id = ?", [.int(sessionID), .int(eventID)])
        try writeMetadata(of: sessionID, in: connection)
    }

    /// Re-cuts the sessions around a content after it was deleted or restored: its context stops
    /// (or starts) to count, so cuts, start reasons and summaries may change. The re-cut covers
    /// everything between the pause-based boundary before the first affected session and the one
    /// after the last, so the result equals a full rebuild. Best effort: a failure only flags a
    /// rebuild and never blocks the user's action.
    static func recut(
        ofContent contentID: Int64, in connection: Connection, configuration: SessionConfiguration
    ) throws {
        try connection.execute("SAVEPOINT session_recut")
        do {
            try recutUnguarded(ofContent: contentID, in: connection, configuration: configuration)
            try connection.execute("RELEASE session_recut")
        } catch {
            try connection.execute("ROLLBACK TO session_recut")
            try connection.execute("RELEASE session_recut")
            try markDirty(in: connection)
        }
    }

    private static func recutUnguarded(
        ofContent contentID: Int64, in connection: Connection, configuration: SessionConfiguration
    ) throws {
        let affected = try connection.query(
            """
            SELECT s.started_at, s.first_event_id FROM sessions s
            WHERE s.id IN (SELECT DISTINCT session_id FROM copy_events WHERE content_id = ?)
            ORDER BY s.started_at, s.first_event_id
            """,
            [.int(contentID)]
        ) { (time: $0.double(0), id: $0.int(1)) }
        guard let earliest = affected.first, let latest = affected.last else { return }
        let start = try anchor(atOrBefore: earliest, in: connection)
        let end = try anchor(after: latest, in: connection)
        try resegment(
            from: start, until: end, preserveFirstStart: start != nil, in: connection,
            configuration: configuration)
    }

    /// Flags that sessions need a rebuild, for example after a failed incremental assignment.
    static func markDirty(in connection: Connection) throws {
        try connection.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, '1')", [.text(dirtyKey)])
    }

    // MARK: - Segmentation and persistence

    @discardableResult
    private static func resegment(
        from start: Key?, until end: Key?, preserveFirstStart: Bool,
        in connection: Connection, configuration: SessionConfiguration
    ) throws -> Int {
        var sql = """
            SELECT e.id, e.copied_at, e.app_bundle_id,
                CASE WHEN c.deleted_at IS NULL THEN e.url END,
                CASE WHEN c.deleted_at IS NULL THEN
                    (SELECT value FROM entities WHERE content_id = e.content_id AND kind = 'repo'
                        ORDER BY value LIMIT 1)
                END
            FROM copy_events e JOIN contents c ON c.id = e.content_id
            """
        var parameters: [SQLValue] = []
        var eventBounds: [String] = []
        var sessionBounds: [String] = []
        if let start {
            eventBounds.append("(e.copied_at, e.id) >= (?, ?)")
            sessionBounds.append("(started_at, first_event_id) >= (?, ?)")
            parameters += [.double(start.time), .int(start.id)]
        }
        if let end {
            eventBounds.append("(e.copied_at, e.id) < (?, ?)")
            sessionBounds.append("(started_at, first_event_id) < (?, ?)")
            parameters += [.double(end.time), .int(end.id)]
        }
        if !eventBounds.isEmpty { sql += " WHERE " + eventBounds.joined(separator: " AND ") }
        sql += " ORDER BY e.copied_at, e.id"
        let events = try connection.query(sql, parameters) { row in
            SessionEvent(
                id: row.int(0), time: Date(timeIntervalSince1970: row.double(1)),
                appBundleID: row.optionalText(2),
                context: row.optionalText(4) ?? row.optionalText(3).flatMap(host(of:)))
        }
        let drafts = SessionSegmenter.segment(events, configuration: configuration)

        let existing = try connection.query(
            sessionBounds.isEmpty
                ? "SELECT id, first_event_id FROM sessions"
                : "SELECT id, first_event_id FROM sessions WHERE "
                    + sessionBounds.joined(separator: " AND "),
            parameters
        ) { (id: $0.int(0), firstEvent: $0.isNull(1) ? nil : $0.int(1)) }
        var sessionByFirstEvent: [Int64: Int64] = [:]
        var staleIDs = Set<Int64>()
        for session in existing {
            if let firstEvent = session.firstEvent { sessionByFirstEvent[firstEvent] = session.id }
            staleIDs.insert(session.id)
        }

        var touched: [Int64] = []
        for (index, draft) in drafts.enumerated() {
            let sessionID: Int64
            if let known = sessionByFirstEvent[draft.firstEventID] {
                sessionID = known
                staleIDs.remove(known)
                try connection.execute(
                    "UPDATE sessions SET started_at = ?, ended_at = ?, event_count = ? WHERE id = ?",
                    [
                        SQLValue(draft.startedAt), SQLValue(draft.endedAt),
                        .int(Int64(draft.events.count)), .int(known),
                    ])
                // The first session of a tail re-cut keeps the reason decided before the tail.
                if !(preserveFirstStart && index == 0) {
                    try connection.execute(
                        "UPDATE sessions SET start_reason = ?, start_detail = ? WHERE id = ?",
                        [.text(draft.start.code), .text(draft.start.detail), .int(known)])
                }
            } else {
                try connection.execute(
                    """
                    INSERT INTO sessions
                        (started_at, ended_at, first_event_id, event_count, start_reason, start_detail)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        SQLValue(draft.startedAt), SQLValue(draft.endedAt),
                        .int(draft.firstEventID),
                        .int(Int64(draft.events.count)), .text(draft.start.code),
                        .text(draft.start.detail),
                    ])
                sessionID = connection.lastInsertRowID
            }
            for ids in draft.events.map(\.id).chunked(into: chunk) {
                let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try connection.execute(
                    "UPDATE copy_events SET session_id = ? WHERE id IN (\(marks)) AND session_id IS NOT ?",
                    [.int(sessionID)] + ids.map(SQLValue.int) + [.int(sessionID)])
            }
            touched.append(sessionID)
        }
        // Summaries are written once every event has its final session.
        for sessionID in touched { try writeMetadata(of: sessionID, in: connection) }
        // Events were reassigned above, so removing stale sessions detaches nothing.
        for id in staleIDs {
            try connection.execute("DELETE FROM sessions WHERE id = ?", [.int(id)])
        }
        return drafts.count
    }

    /// Event count, dominant apps and recurring entities, counted over items that are not deleted.
    private static func writeMetadata(of sessionID: Int64, in connection: Connection) throws {
        let apps = try connection.query(
            """
            SELECT e.app_bundle_id, count(*) AS n FROM copy_events e
            JOIN contents c ON c.id = e.content_id AND c.deleted_at IS NULL
            WHERE e.session_id = ? AND e.app_bundle_id IS NOT NULL
            GROUP BY e.app_bundle_id ORDER BY n DESC, e.app_bundle_id LIMIT ?
            """,
            [.int(sessionID), .int(Int64(topApps))]
        ) { SessionSummary.AppShare(bundleID: $0.text(0), count: Int($0.int(1))) }

        let kinds = entityKinds.map { "'\($0)'" }.joined(separator: ",")
        let entities = try connection.query(
            """
            SELECT n.kind, n.value, count(DISTINCT e.id) AS cnt FROM copy_events e
            JOIN contents c ON c.id = e.content_id AND c.deleted_at IS NULL
            JOIN entities n ON n.content_id = c.id AND n.kind IN (\(kinds))
            WHERE e.session_id = ?
            GROUP BY n.kind, n.value ORDER BY cnt DESC, n.kind, n.value LIMIT ?
            """,
            [.int(sessionID), .int(Int64(topEntities))]
        ) {
            SessionSummary.EntityShare(kind: $0.text(0), value: $0.text(1), count: Int($0.int(2)))
        }
        let liveEvents =
            try connection.query(
                """
                SELECT count(*) FROM copy_events e
                JOIN contents c ON c.id = e.content_id AND c.deleted_at IS NULL
                WHERE e.session_id = ?
                """,
                [.int(sessionID)]
            ) { $0.int(0) }.first ?? 0
        try connection.execute(
            """
            UPDATE sessions SET dominant_apps = ?, top_entities = ?, event_count = ? WHERE id = ?
            """,
            [.text(encode(apps)), .text(encode(entities)), .int(liveEvents), .int(sessionID)])
    }

    private static func encode<T: Encodable>(_ value: [T]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func decode<T: Decodable>(_ text: String) -> [T] {
        (try? JSONDecoder().decode([T].self, from: Data(text.utf8))) ?? []
    }

    /// Lower-cased host without a leading `www.`, nil for anything that is not a web address.
    static func host(of address: String) -> String? {
        guard let host = URL(string: address)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

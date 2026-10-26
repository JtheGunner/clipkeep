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
            try Self.resegment(from: nil, in: connection, configuration: configuration)
        }
    }

    public func sessions(limit: Int = 50, before: Date? = nil) throws -> [SessionSummary] {
        guard limit > 0 else { return [] }
        return try database.read { connection in
            try connection.query(
                """
                SELECT id, started_at, ended_at, event_count, start_reason, start_detail,
                    dominant_apps, top_entities, topic_id
                FROM sessions WHERE started_at < ?
                ORDER BY started_at DESC, id DESC LIMIT ?
                """,
                [SQLValue(before ?? Date.distantFuture), .int(Int64(limit))]
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

    /// Assigns a freshly inserted event. Only the newest session (the "tail") is re-cut; an event
    /// that lands before the tail triggers a full rebuild. Runs inside the caller's transaction.
    static func assign(
        eventID: Int64, in connection: Connection, configuration: SessionConfiguration
    ) throws {
        let tailStart = try connection.query(
            """
            SELECT e.copied_at, e.id FROM sessions s
            JOIN copy_events e ON e.id = s.first_event_id
            ORDER BY s.started_at DESC, s.id DESC LIMIT 1
            """
        ) { (time: $0.double(0), id: $0.int(1)) }.first
        let event = try connection.query(
            "SELECT copied_at FROM copy_events WHERE id = ?", [.int(eventID)]
        ) { $0.double(0) }.first

        guard let tailStart, let event else {
            try resegment(from: nil, in: connection, configuration: configuration)
            return
        }
        if (event, eventID) < (tailStart.time, tailStart.id) {
            try resegment(from: nil, in: connection, configuration: configuration)
        } else {
            try resegment(from: tailStart, in: connection, configuration: configuration)
        }
    }

    // MARK: - Segmentation and persistence

    @discardableResult
    private static func resegment(
        from start: (time: Double, id: Int64)?, in connection: Connection,
        configuration: SessionConfiguration
    ) throws -> Int {
        var sql = """
            SELECT e.id, e.copied_at, e.app_bundle_id, e.url,
                (SELECT value FROM entities WHERE content_id = e.content_id AND kind = 'repo'
                    ORDER BY value LIMIT 1)
            FROM copy_events e
            """
        var parameters: [SQLValue] = []
        if let start {
            sql += " WHERE (e.copied_at, e.id) >= (?, ?)"
            parameters = [.double(start.time), .int(start.id)]
        }
        sql += " ORDER BY e.copied_at, e.id"
        let events = try connection.query(sql, parameters) { row in
            SessionEvent(
                id: row.int(0), time: Date(timeIntervalSince1970: row.double(1)),
                appBundleID: row.optionalText(2),
                context: row.optionalText(4) ?? row.optionalText(3).flatMap(host(of:)))
        }
        let drafts = SessionSegmenter.segment(events, configuration: configuration)

        let existing = try connection.query(
            start == nil
                ? "SELECT id, first_event_id FROM sessions"
                : """
                SELECT id, first_event_id FROM sessions WHERE first_event_id IN
                    (SELECT id FROM copy_events WHERE (copied_at, id) >= (?, ?))
                """,
            parameters
        ) { (id: $0.int(0), firstEvent: $0.isNull(1) ? nil : $0.int(1)) }
        var sessionByFirstEvent: [Int64: Int64] = [:]
        var staleIDs = Set<Int64>()
        for session in existing {
            if let firstEvent = session.firstEvent { sessionByFirstEvent[firstEvent] = session.id }
            staleIDs.insert(session.id)
        }

        for draft in drafts {
            let sessionID: Int64
            if let known = sessionByFirstEvent[draft.firstEventID] {
                sessionID = known
                staleIDs.remove(known)
                try connection.execute(
                    """
                    UPDATE sessions SET started_at = ?, ended_at = ?, event_count = ?,
                        start_reason = ?, start_detail = ?
                    WHERE id = ?
                    """,
                    [
                        SQLValue(draft.startedAt), SQLValue(draft.endedAt),
                        .int(Int64(draft.events.count)), .text(draft.start.code),
                        .text(draft.start.detail), .int(known),
                    ])
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
            try writeMetadata(of: sessionID, in: connection)
        }
        // Events were reassigned above, so removing stale sessions detaches nothing.
        for id in staleIDs {
            try connection.execute("DELETE FROM sessions WHERE id = ?", [.int(id)])
        }
        return drafts.count
    }

    /// Dominant apps and recurring entities, counted over items that are not deleted.
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
        try connection.execute(
            "UPDATE sessions SET dominant_apps = ?, top_entities = ? WHERE id = ?",
            [.text(encode(apps)), .text(encode(entities)), .int(sessionID)])
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

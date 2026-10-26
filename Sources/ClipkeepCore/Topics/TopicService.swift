import Foundation

public struct TopicSummary: Sendable, Equatable {
    public let id: Int64
    public let label: String
    public let keywords: [String]
    public let sessionCount: Int
    public let startedAt: Date
    public let endedAt: Date
    public let labelIsManual: Bool
}

/// Where a session stands in the topic structure, and why.
public struct SessionTopic: Sendable, Equatable {
    public let topicID: Int64?
    /// Sentence for the user, for example "gleiches Repo github.com/acme/api (Ähnlichkeit 62 %)".
    public let reason: String
    public let similarity: Double
    /// True after a manual assignment; clustering never moves locked sessions.
    public let isLocked: Bool
}

/// Groups sessions into topics with TF-IDF similarity and structural signals, locally and
/// without any model. Manual corrections (assign, split, merge, rename) survive recomputation.
public struct TopicService: Sendable {
    private static let maximumContentsPerSession = 300
    private static let charactersPerContent = 2_000
    private static let secretLookahead = 512
    private static let storedTerms = 200
    private static let storedFeatures = 20
    /// Bounds the first run after an upgrade; the rest follows in later runs.
    private static let maximumSessionsPerRun = 500
    private static let structuralKinds = ["repo", "domain", "ticket"]

    private let database: Database
    private let configuration: TopicConfiguration

    public init(database: Database, configuration: TopicConfiguration = .default) {
        self.database = database
        self.configuration = configuration
    }

    // MARK: - Clustering

    /// Indexes changed sessions and places settled, unassigned sessions into topics. Existing
    /// assignments stay as they are. Returns the number of newly placed sessions.
    @discardableResult
    public func cluster(now: Date = Date()) throws -> Int {
        let reindexed = try indexStaleSessions()
        return try database.write { connection in
            try run(in: connection, now: now, full: false, reindexed: reindexed)
        }
    }

    /// Recomputes all automatic assignments from scratch. Manually placed sessions, manual labels
    /// and topic ids of topics whose oldest session is unchanged are kept.
    @discardableResult
    public func recluster(now: Date = Date()) throws -> Int {
        let reindexed = try indexStaleSessions()
        return try database.write { connection in
            try run(in: connection, now: now, full: true, reindexed: reindexed)
        }
    }

    private func run(in connection: Connection, now: Date, full: Bool, reindexed: Int) throws -> Int
    {
        let settledBefore = now.addingTimeInterval(-configuration.settleMinutes * 60)
            .timeIntervalSince1970
        let released = try Self.releaseInvisibleSessions(in: connection)
        let sessions = try Self.loadSessions(in: connection)
        let corpus = sessions.map(\.document)

        let isFree: (LoadedSession) -> Bool = { session in
            guard !session.isLocked, session.endedAt <= settledBefore else { return false }
            return full || session.topicID == nil
        }
        let free = sessions.filter(isFree)
        if full {
            for session in free where session.topicID != nil {
                try connection.execute(
                    "UPDATE sessions SET topic_id = NULL, topic_reason = '', topic_score = 0 WHERE id = ?",
                    [.int(session.document.id)])
            }
        }
        var fixed: [Int64: Int64] = [:]
        for session in sessions where !(full && isFree(session)) {
            if let topic = session.topicID { fixed[session.document.id] = topic }
        }

        let placements = TopicClusterer.place(
            free: free.map(\.document), fixed: fixed, corpus: corpus, configuration: configuration)

        // Topics left without sessions can give their id to a new topic with the same oldest session.
        var reusable: [Int64: Int64] = [:]
        for row in try connection.query(
            """
            SELECT id, anchor_session_id FROM topics
            WHERE anchor_session_id IS NOT NULL
                AND anchor_session_id IN (SELECT id FROM sessions)
                AND id NOT IN (SELECT topic_id FROM sessions WHERE topic_id IS NOT NULL)
            """
        ) { (id: $0.int(0), anchor: $0.int(1)) } {
            reusable[row.anchor] = row.id
        }

        var topicForGroup: [Int: Int64] = [:]
        var firstOfGroup: [Int: Int64] = [:]
        let ordered = free.map(\.document).sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        for document in ordered {
            guard let placement = placements[document.id] else { continue }
            switch placement {
            case .existing(let topic, let reason):
                try Self.assign(
                    document.id, to: topic, reason: reason.text, score: reason.similarity,
                    locked: false, in: connection)
            case .new(let group, let reason):
                let topic: Int64
                if let known = topicForGroup[group] {
                    topic = known
                } else {
                    if let reused = reusable.removeValue(forKey: document.id) {
                        topic = reused
                    } else {
                        try connection.execute(
                            "INSERT INTO topics (label, created_at) VALUES ('', ?)", [SQLValue(now)]
                        )
                        topic = connection.lastInsertRowID
                    }
                    topicForGroup[group] = topic
                    firstOfGroup[group] = document.id
                }
                try Self.assign(
                    document.id, to: topic,
                    reason: reason?.text ?? "Erste Session dieses Themas",
                    score: reason?.similarity ?? 1, locked: false, in: connection)
            }
        }
        // Keywords and labels also change when a session was re-indexed or left its topic.
        if full || !placements.isEmpty || reindexed > 0 || released > 0 {
            try Self.refreshAllTopics(in: connection, configuration: configuration)
        }
        return placements.count
    }

    // MARK: - Reading

    public func topics(limit: Int = 100) throws -> [TopicSummary] {
        guard limit > 0 else { return [] }
        return try database.read { connection in
            try connection.query(
                """
                SELECT t.id, t.label, t.keywords, t.label_is_manual,
                    count(s.id), min(s.started_at), max(s.ended_at)
                FROM topics t JOIN sessions s ON s.topic_id = t.id
                GROUP BY t.id ORDER BY max(s.ended_at) DESC, t.id DESC LIMIT ?
                """,
                [.int(Int64(limit))]
            ) { row in
                TopicSummary(
                    id: row.int(0), label: row.text(1), keywords: Self.decode(row.text(2)),
                    sessionCount: Int(row.int(4)),
                    startedAt: Date(timeIntervalSince1970: row.double(5)),
                    endedAt: Date(timeIntervalSince1970: row.double(6)),
                    labelIsManual: row.int(3) != 0)
            }
        }
    }

    public func sessionIDs(inTopic topicID: Int64) throws -> [Int64] {
        try database.read { connection in
            try connection.query(
                "SELECT id FROM sessions WHERE topic_id = ? ORDER BY started_at, id",
                [.int(topicID)]
            ) { $0.int(0) }
        }
    }

    public func topic(ofSession sessionID: Int64) throws -> SessionTopic? {
        try database.read { connection in
            try connection.query(
                "SELECT topic_id, topic_reason, topic_score, topic_locked FROM sessions WHERE id = ?",
                [.int(sessionID)]
            ) {
                SessionTopic(
                    topicID: $0.isNull(0) ? nil : $0.int(0), reason: $0.text(1),
                    similarity: $0.double(2), isLocked: $0.int(3) != 0)
            }.first
        }
    }

    // MARK: - Manual corrections

    /// Puts a session into a topic and keeps it there. Returns false if either does not exist.
    @discardableResult
    public func assign(sessionID: Int64, toTopic topicID: Int64) throws -> Bool {
        try database.write { connection in
            guard try Self.exists("sessions", sessionID, connection),
                try Self.exists("topics", topicID, connection)
            else { return false }
            let old = try Self.topicID(ofSession: sessionID, connection)
            try Self.assign(
                sessionID, to: topicID, reason: "Manuell zugeordnet", score: 1, locked: true,
                in: connection)
            try Self.cleanUpAndRefresh(
                Set([old, topicID].compactMap { $0 }), connection, configuration)
            return true
        }
    }

    /// Moves a session into a new topic of its own and keeps it there.
    /// Returns the new topic's id, or nil if the session does not exist.
    @discardableResult
    public func splitOff(sessionID: Int64, now: Date = Date()) throws -> Int64? {
        try database.write { connection in
            guard try Self.exists("sessions", sessionID, connection) else { return nil }
            let old = try Self.topicID(ofSession: sessionID, connection)
            try connection.execute(
                "INSERT INTO topics (label, created_at) VALUES ('', ?)", [SQLValue(now)])
            let topic = connection.lastInsertRowID
            try Self.assign(
                sessionID, to: topic, reason: "Manuell abgetrennt", score: 1, locked: true,
                in: connection)
            try Self.cleanUpAndRefresh(
                Set([old, topic].compactMap { $0 }), connection, configuration)
            return topic
        }
    }

    /// Moves every session of `source` into `target` and locks the whole topic; `source` disappears.
    @discardableResult
    public func merge(topic source: Int64, into target: Int64) throws -> Bool {
        guard source != target else { return false }
        return try database.write { connection in
            guard try Self.exists("topics", source, connection),
                try Self.exists("topics", target, connection)
            else { return false }
            try connection.execute(
                """
                UPDATE sessions SET topic_id = ?, topic_locked = 1, topic_reason = 'Manuell zusammengeführt',
                    topic_score = 1 WHERE topic_id = ?
                """,
                [.int(target), .int(source)])
            // The merged topic is the user's decision, so its other sessions stay together too.
            try connection.execute(
                "UPDATE sessions SET topic_locked = 1 WHERE topic_id = ?", [.int(target)])
            try Self.cleanUpAndRefresh(Set([source, target]), connection, configuration)
            return true
        }
    }

    /// Sets a label by hand and keeps the topic's sessions together; an empty label returns to the
    /// automatic one.
    @discardableResult
    public func rename(topic topicID: Int64, to label: String) throws -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.write { connection in
            guard try Self.exists("topics", topicID, connection) else { return false }
            try connection.execute(
                "UPDATE topics SET label = ?, label_is_manual = ? WHERE id = ?",
                [.text(trimmed), .int(trimmed.isEmpty ? 0 : 1), .int(topicID)])
            if !trimmed.isEmpty {
                // A named topic is the user's decision: its sessions stay together on recomputation.
                try connection.execute(
                    "UPDATE sessions SET topic_locked = 1 WHERE topic_id = ?", [.int(topicID)])
            }
            try Self.cleanUpAndRefresh([topicID], connection, configuration)
            return true
        }
    }

    // MARK: - Indexing

    /// Computes word counts and structural signals for sessions whose content changed.
    /// Tokenizing runs outside the write transaction. Returns the number of sessions indexed.
    private func indexStaleSessions() throws -> Int {
        let stale = try database.read { connection in
            try connection.query(
                "SELECT id, event_count FROM sessions WHERE indexed_events != event_count ORDER BY id LIMIT ?",
                [.int(Int64(Self.maximumSessionsPerRun))]
            ) { (id: $0.int(0), count: $0.int(1)) }
        }
        for batch in stride(from: 0, to: stale.count, by: 50).map({
            Array(stale[$0..<min($0 + 50, stale.count)])
        }) {
            let indexed = try batch.map { session -> (Int64, Int64, String, String) in
                let input = try database.read { try Self.inputs(ofSession: session.id, in: $0) }
                let counts = Self.mergedCounts(input.texts)
                return (session.id, session.count, Self.encode(counts), Self.encode(input.features))
            }
            try database.write { connection in
                for (id, count, terms, features) in indexed {
                    try connection.execute(
                        "UPDATE sessions SET term_counts = ?, features = ?, indexed_events = ? WHERE id = ?",
                        [.text(terms), .text(features), .int(count), .int(id)])
                }
            }
        }
        return stale.count
    }

    private static let detector = SecretDetector()

    private static func inputs(ofSession id: Int64, in connection: Connection) throws -> (
        texts: [String], features: [String]
    ) {
        let texts = try connection.query(
            """
            SELECT substr(c.text, 1, ?) FROM contents c
            WHERE c.deleted_at IS NULL
                AND c.id IN (SELECT DISTINCT content_id FROM copy_events WHERE session_id = ?)
            ORDER BY c.id LIMIT ?
            """,
            [
                .int(Int64(charactersPerContent + secretLookahead)), .int(id),
                .int(Int64(maximumContentsPerSession)),
            ]
        ) { $0.text(0) }
        // The secret check sees a little past the cut-off, so a key straddling it is still caught.
        .filter { !detector.containsSecret(in: $0) }.map { String($0.prefix(charactersPerContent)) }

        let kinds = structuralKinds.map { "'\($0)'" }.joined(separator: ",")
        var features = Set(
            try connection.query(
                """
                SELECT DISTINCT n.kind, n.value FROM entities n
                JOIN contents c ON c.id = n.content_id AND c.deleted_at IS NULL
                WHERE n.kind IN (\(kinds))
                    AND n.content_id IN (SELECT content_id FROM copy_events WHERE session_id = ?)
                """,
                [.int(id)]
            ) { "\($0.text(0)):\($0.text(1))" })
        let urls = try connection.query(
            """
            SELECT DISTINCT e.url FROM copy_events e
            JOIN contents c ON c.id = e.content_id AND c.deleted_at IS NULL
            WHERE e.session_id = ? AND e.url IS NOT NULL
            """,
            [.int(id)]
        ) { $0.text(0) }
        for url in urls {
            if let host = SessionService.host(of: url) { features.insert("domain:\(host)") }
        }
        // Strongest signals first, so the cap never drops a repo or ticket in favour of hosts.
        let priority = Dictionary(
            uniqueKeysWithValues: structuralKinds.enumerated().map { ($1, $0) })
        let ranked = features.sorted {
            let lhs = priority[String($0.prefix { $0 != ":" })] ?? structuralKinds.count
            let rhs = priority[String($1.prefix { $0 != ":" })] ?? structuralKinds.count
            return (lhs, $0) < (rhs, $1)
        }
        return (texts, Array(ranked.prefix(storedFeatures)))
    }

    private static func mergedCounts(_ texts: [String]) -> [String: Int] {
        var total: [String: Int] = [:]
        var budget = TermTokenizer.maximumCharacters
        for text in texts where budget > 0 {
            let slice = String(text.prefix(budget))
            budget -= slice.count
            for (term, count) in TermTokenizer.counts(in: slice) {
                total[term, default: 0] += count
            }
        }
        let top = total.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(storedTerms)
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
    }

    // MARK: - Shared helpers

    private struct LoadedSession {
        let document: TopicDocument
        let endedAt: Double
        let topicID: Int64?
        let isLocked: Bool
    }

    private static func loadSessions(in connection: Connection) throws -> [LoadedSession] {
        try connection.query(
            """
            SELECT id, started_at, ended_at, term_counts, features, topic_id, topic_locked
            FROM sessions
            WHERE event_count > 0 AND indexed_events = event_count
                AND (term_counts != '{}' OR features != '[]')
            """
        ) { row in
            LoadedSession(
                document: TopicDocument(
                    id: row.int(0), time: Date(timeIntervalSince1970: row.double(1)),
                    terms: decode(row.text(3)), features: decode(row.text(4))),
                endedAt: row.double(2), topicID: row.isNull(5) ? nil : row.int(5),
                isLocked: row.int(6) != 0)
        }
    }

    /// Sessions without any live item are invisible, so they leave their topic, locked or not.
    @discardableResult
    private static func releaseInvisibleSessions(in connection: Connection) throws -> Int {
        try connection.execute(
            """
            UPDATE sessions SET topic_id = NULL, topic_locked = 0, topic_reason = '', topic_score = 0
            WHERE topic_id IS NOT NULL AND event_count = 0
            """)
        return connection.changedRowCount
    }

    private static func assign(
        _ sessionID: Int64, to topicID: Int64, reason: String, score: Double, locked: Bool,
        in connection: Connection
    ) throws {
        try connection.execute(
            """
            UPDATE sessions SET topic_id = ?, topic_reason = ?, topic_score = ?, topic_locked = ?
            WHERE id = ?
            """,
            [.int(topicID), .text(reason), .double(score), .int(locked ? 1 : 0), .int(sessionID)])
    }

    private static func exists(_ table: String, _ id: Int64, _ connection: Connection) throws
        -> Bool
    {
        try !connection.query("SELECT 1 FROM \(table) WHERE id = ?", [.int(id)]) { _ in 1 }.isEmpty
    }

    private static func topicID(ofSession id: Int64, _ connection: Connection) throws -> Int64? {
        try connection.query("SELECT topic_id FROM sessions WHERE id = ?", [.int(id)]) {
            $0.isNull(0) ? nil : $0.int(0)
        }.first ?? nil
    }

    private static func cleanUpAndRefresh(
        _ topics: Set<Int64>, _ connection: Connection, _ configuration: TopicConfiguration
    ) throws {
        // Only the touched topics need new anchors, labels and keywords; empty ones disappear.
        try refreshAllTopics(in: connection, configuration: configuration, only: topics)
    }

    /// Removes empty topics and recomputes anchor session, keywords and automatic labels.
    private static func refreshAllTopics(
        in connection: Connection, configuration: TopicConfiguration, only subset: Set<Int64>? = nil
    ) throws {
        try releaseInvisibleSessions(in: connection)
        try connection.execute(
            "DELETE FROM topics WHERE id NOT IN (SELECT topic_id FROM sessions WHERE topic_id IS NOT NULL)"
        )
        let ids = try connection.query("SELECT id FROM topics") { $0.int(0) }.filter {
            subset?.contains($0) ?? true
        }
        let corpus = try loadSessions(in: connection).map(\.document)
        let idf = TopicClusterer.inverseDocumentFrequencies(corpus)
        let byID = Dictionary(uniqueKeysWithValues: corpus.map { ($0.id, $0) })

        // Anchors are unique, so clear them first and set them again once all members are known.
        for id in ids {
            try connection.execute(
                "UPDATE topics SET anchor_session_id = NULL WHERE id = ?", [.int(id)])
        }
        for id in ids {
            let members = try connection.query(
                "SELECT id FROM sessions WHERE topic_id = ? ORDER BY started_at, id", [.int(id)]
            ) { $0.int(0) }
            guard let anchor = members.first else {
                try connection.execute("DELETE FROM topics WHERE id = ?", [.int(id)])
                continue
            }
            let documents = members.compactMap { byID[$0] }
            let keywords = TopicClusterer.keywords(
                of: documents, idf: idf, configuration: configuration)
            // A repo names a topic best, then a ticket, then a website.
            let priority = ["repo": 0, "ticket": 1, "domain": 2]
            func rank(_ feature: String) -> Int {
                priority[String(feature.prefix { $0 != ":" })] ?? 3
            }
            let values = keywords.features.enumerated().sorted {
                (rank($0.element), $0.offset) < (rank($1.element), $1.offset)
            }.map(\.element).compactMap {
                $0.split(separator: ":", maxSplits: 1).last.map(String.init)
            }
            let stored = values + keywords.terms
            let automaticLabel =
                values.first
                ?? (keywords.terms.prefix(3).joined(separator: ", ").nonEmpty ?? "Thema")
            try connection.execute(
                """
                UPDATE topics SET anchor_session_id = ?, keywords = ?,
                    label = CASE WHEN label_is_manual = 1 THEN label ELSE ? END
                WHERE id = ?
                """,
                [.int(anchor), .text(encode(stored)), .text(automaticLabel), .int(id)])
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func decode<T: Decodable & ExpressibleByArrayLiteral>(_ text: String) -> T {
        (try? JSONDecoder().decode(T.self, from: Data(text.utf8))) ?? []
    }

    private static func decode(_ text: String) -> [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(text.utf8))) ?? [:]
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

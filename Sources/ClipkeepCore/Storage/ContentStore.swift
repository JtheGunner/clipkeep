import Foundation

/// Where a copy came from. Every field is optional because permissions may be missing.
public struct CopyContext: Sendable, Equatable {
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?

    public init(
        appBundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil,
        url: String? = nil
    ) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
    }
}

public struct RecordedCopy: Sendable, Equatable {
    public let contentID: Int64
    public let eventID: Int64
    public let isNewContent: Bool
}

/// Stores each distinct text once and one event per copy, so frequency falls out of the events.
public struct ContentStore: Sendable {
    private let database: Database
    private let duplicates: DuplicateConfiguration
    private let ranking: RankingConfiguration
    private let sessions: SessionConfiguration?

    /// `sessions: nil` skips the incremental session assignment, for bulk imports that call
    /// `SessionService.rebuild` once at the end.
    public init(
        database: Database, duplicates: DuplicateConfiguration = .default,
        ranking: RankingConfiguration = .default, sessions: SessionConfiguration? = .default
    ) {
        self.database = database
        self.duplicates = duplicates
        self.ranking = ranking
        self.sessions = sessions
    }

    /// Analysis of a text that is stored for the first time. Computed outside the write
    /// transaction so classification never holds the database lock.
    private struct Analysis {
        let normalizedHash: String
        let searchText: String
        let kind: ContentKind
        let entities: [Entity]
        let fingerprint: UInt64?

        init(text: String) {
            normalizedHash = ContentHashing.normalizedHash(text)
            searchText = SearchText.fold(text)
            kind = ContentClassifier.classify(text)
            entities = EntityExtractor.extract(from: text)
            fingerprint = SimHash.fingerprint(foldedText: searchText)
        }
    }

    /// - Parameters:
    ///   - kind: replaces the classified kind of a text stored for the first time.
    ///   - inTransaction: runs in the same transaction after the copy was stored; if it throws,
    ///     nothing of the copy is kept.
    public func record(
        text: String, copiedAt: Date = Date(), context: CopyContext = CopyContext(),
        kind: ContentKind? = nil,
        inTransaction: ((Connection, RecordedCopy) throws -> Void)? = nil
    ) throws -> RecordedCopy {
        let hash = ContentHashing.exactHash(text)
        let isKnown = try database.read { connection in
            try !connection.query("SELECT 1 FROM contents WHERE hash = ?", [.text(hash)]) { _ in 1 }
                .isEmpty
        }
        let prepared = isKnown ? nil : Analysis(text: text)

        return try database.write { connection in
            let existing = try connection.query(
                "SELECT id FROM contents WHERE hash = ?", [.text(hash)]
            ) { $0.int(0) }

            let contentID: Int64
            let isNew = existing.isEmpty
            if let id = existing.first {
                contentID = id
                // Copying a deleted text again brings it back, with its pin, star and feedback.
                let wasDeleted =
                    try connection.query(
                        "SELECT 1 FROM contents WHERE id = ? AND deleted_at IS NOT NULL", [.int(id)]
                    ) { _ in 1 }.isEmpty == false
                if wasDeleted, let before = try ItemActions.snapshot(of: id, in: connection) {
                    try connection.execute(
                        "UPDATE contents SET deleted_at = NULL WHERE id = ?", [.int(id)])
                    try ItemActions.log(
                        .recopy, contentID: id, snapshot: before, now: copiedAt, in: connection)
                }
            } else {
                // The content vanished between the lookup and the write (a deletion); analyse now.
                let analysis = prepared ?? Analysis(text: text)
                try connection.execute(
                    """
                    INSERT INTO contents
                        (hash, normalized_hash, text, search_text, kind, first_seen_at, last_copied_at,
                         simhash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(hash), .text(analysis.normalizedHash), .text(text),
                        .text(analysis.searchText), .text((kind ?? analysis.kind).rawValue),
                        SQLValue(copiedAt), SQLValue(copiedAt),
                        analysis.fingerprint.map { .int(Int64(bitPattern: $0)) } ?? .null,
                    ])
                contentID = connection.lastInsertRowID
                try linkDuplicates(of: contentID, analysis: analysis, in: connection)
                for entity in analysis.entities {
                    try connection.execute(
                        "INSERT OR IGNORE INTO entities (content_id, kind, value) VALUES (?, ?, ?)",
                        [.int(contentID), .text(entity.kind.rawValue), .text(entity.value)])
                }
            }

            try connection.execute(
                """
                INSERT INTO copy_events
                    (content_id, copied_at, app_bundle_id, app_name, window_title, url)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .int(contentID), SQLValue(copiedAt), SQLValue(context.appBundleID),
                    SQLValue(context.appName), SQLValue(context.windowTitle),
                    SQLValue(context.url),
                ])
            let eventID = connection.lastInsertRowID
            if let sessions {
                // Sessions are best effort: a failure must not lose the copy, it only flags
                // the sessions for a rebuild (`SessionService.rebuildIfNeeded`).
                try connection.execute("SAVEPOINT sessions")
                do {
                    try SessionService.assign(
                        eventID: eventID, in: connection, configuration: sessions)
                    try connection.execute("RELEASE sessions")
                } catch {
                    try connection.execute("ROLLBACK TO sessions")
                    try connection.execute("RELEASE sessions")
                    try SessionService.markDirty(in: connection)
                }
            }
            try RankingService.refresh(
                contentID: contentID, in: connection, configuration: ranking, now: copiedAt)
            let recorded = RecordedCopy(contentID: contentID, eventID: eventID, isNewContent: isNew)
            try inTransaction?(connection, recorded)
            return recorded
        }
    }

    public func occurrenceCount(contentID: Int64) throws -> Int {
        try database.read { connection in
            try connection.query(
                "SELECT count(*) FROM copy_events WHERE content_id = ?", [.int(contentID)]
            ) { Int($0.int(0)) }.first ?? 0
        }
    }

    /// Indexes the fingerprint and links the content to earlier ones with the same normalized text
    /// or a close SimHash. Existing rows are never touched, so no copy or event is lost by
    /// detecting a duplicate. The bands are written even when linking is off, so re-enabling it
    /// later still finds everything stored in between.
    private func linkDuplicates(
        of contentID: Int64, analysis: Analysis, in connection: Connection
    ) throws {
        let bands = analysis.fingerprint.map(FingerprintBands.values(of:))
        let candidates = try duplicateLinkCandidates(
            of: contentID, analysis: analysis, bands: bands, in: connection)
        if let fingerprint = analysis.fingerprint, let bands {
            for (band, value) in bands.enumerated() {
                try connection.execute(
                    """
                    INSERT INTO content_bands (content_id, band, value, simhash)
                    VALUES (?, ?, ?, ?)
                    """,
                    [
                        .int(contentID), .int(Int64(band)), .int(value),
                        .int(Int64(bitPattern: fingerprint)),
                    ])
            }
        }
        for link in candidates {
            try connection.execute(
                """
                INSERT INTO content_links (content_id, related_id, kind, distance)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .int(link.contentID), .int(link.relatedID), .text(link.kind.rawValue),
                    .int(Int64(link.distance)),
                ])
        }
    }

    private func duplicateLinkCandidates(
        of contentID: Int64, analysis: Analysis, bands: [Int64]?, in connection: Connection
    ) throws -> [DuplicateLink] {
        guard duplicates.maximumLinks > 0 else { return [] }
        var links: [DuplicateLink] = try connection.query(
            """
            SELECT id FROM contents
            WHERE normalized_hash = ? AND id != ? AND deleted_at IS NULL
            ORDER BY id LIMIT ?
            """,
            [.text(analysis.normalizedHash), .int(contentID), .int(Int64(duplicates.maximumLinks))]
        ) {
            DuplicateLink(
                contentID: contentID, relatedID: $0.int(0), kind: .normalized, distance: 0)
        }

        if let fingerprint = analysis.fingerprint, let bands {
            var seen = Set(links.map(\.relatedID))
            var near: [DuplicateLink] = []
            for (band, value) in bands.enumerated() {
                let rows = try connection.query(
                    """
                    SELECT b.content_id, b.simhash FROM content_bands b
                    JOIN contents c ON c.id = b.content_id AND c.deleted_at IS NULL
                    WHERE b.band = ? AND b.value = ? AND b.content_id != ?
                    """,
                    [.int(Int64(band)), .int(value), .int(contentID)]
                ) { (id: $0.int(0), hash: UInt64(bitPattern: $0.int(1))) }
                for row in rows where seen.insert(row.id).inserted {
                    let distance = SimHash.distance(fingerprint, row.hash)
                    if distance <= duplicates.maximumDistance {
                        near.append(
                            DuplicateLink(
                                contentID: contentID, relatedID: row.id, kind: .near,
                                distance: distance))
                    }
                }
            }
            near.sort { ($0.distance, $0.relatedID) < ($1.distance, $1.relatedID) }
            links += near
        }
        return Array(links.prefix(duplicates.maximumLinks))
    }

    /// Fingerprints and indexes contents stored before duplicate detection existed, so new copies
    /// can find them. Returns how many were processed; call repeatedly until it returns 0.
    /// Old rows are not linked to each other.
    @discardableResult
    public func indexUnfingerprintedContents(batchSize: Int = 200) throws -> Int {
        let rows = try database.read { connection in
            try connection.query(
                "SELECT id, search_text FROM contents WHERE simhash IS NULL ORDER BY id LIMIT ?",
                [.int(Int64(max(batchSize, 1)))]
            ) { (id: $0.int(0), searchText: $0.text(1)) }
        }
        guard !rows.isEmpty else { return 0 }
        let fingerprints = rows.map { SimHash.fingerprint(foldedText: $0.searchText) }
        try database.write { connection in
            for (row, fingerprint) in zip(rows, fingerprints) {
                guard let fingerprint else {
                    // Too short to fingerprint: store 0 without bands so it is not picked again.
                    try connection.execute(
                        "UPDATE contents SET simhash = 0 WHERE id = ?", [.int(row.id)])
                    continue
                }
                try connection.execute(
                    "UPDATE contents SET simhash = ? WHERE id = ?",
                    [.int(Int64(bitPattern: fingerprint)), .int(row.id)])
                for (band, value) in FingerprintBands.values(of: fingerprint).enumerated() {
                    try connection.execute(
                        """
                        INSERT OR IGNORE INTO content_bands (content_id, band, value, simhash)
                        VALUES (?, ?, ?, ?)
                        """,
                        [
                            .int(row.id), .int(Int64(band)), .int(value),
                            .int(Int64(bitPattern: fingerprint)),
                        ])
                }
            }
        }
        return rows.count
    }

    /// Links in both directions: contents this one resembles and contents that resemble it.
    public func duplicateLinks(of contentID: Int64) throws -> [DuplicateLink] {
        try database.read { connection in
            try connection.query(
                """
                SELECT l.content_id, l.related_id, l.kind, l.distance FROM content_links l
                JOIN contents a ON a.id = l.content_id AND a.deleted_at IS NULL
                JOIN contents b ON b.id = l.related_id AND b.deleted_at IS NULL
                WHERE l.content_id = ?1 OR l.related_id = ?1
                ORDER BY l.distance, l.content_id, l.related_id
                LIMIT 100
                """,
                [.int(contentID)]
            ) { row in
                DuplicateKind(rawValue: row.text(2)).map {
                    DuplicateLink(
                        contentID: row.int(0), relatedID: row.int(1), kind: $0,
                        distance: Int(row.int(3)))
                }
            }.compactMap { $0 }
        }
    }
}

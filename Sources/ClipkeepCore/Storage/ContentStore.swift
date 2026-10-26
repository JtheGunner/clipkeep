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

    public init(database: Database, duplicates: DuplicateConfiguration = .default) {
        self.database = database
        self.duplicates = duplicates
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
            fingerprint = SimHash.fingerprint(of: text)
        }
    }

    public func record(
        text: String, copiedAt: Date = Date(), context: CopyContext = CopyContext()
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
                        .text(analysis.searchText), .text(analysis.kind.rawValue),
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
            return RecordedCopy(
                contentID: contentID, eventID: connection.lastInsertRowID, isNewContent: isNew)
        }
    }

    public func occurrenceCount(contentID: Int64) throws -> Int {
        try database.read { connection in
            try connection.query(
                "SELECT count(*) FROM copy_events WHERE content_id = ?", [.int(contentID)]
            ) { Int($0.int(0)) }.first ?? 0
        }
    }

    /// Links to contents with the same normalized text or a close SimHash. Existing rows are
    /// never touched, so no copy or event is lost by detecting a duplicate.
    private func linkDuplicates(
        of contentID: Int64, analysis: Analysis, in connection: Connection
    ) throws {
        guard duplicates.maximumLinks > 0 else { return }
        var links: [DuplicateLink] = try connection.query(
            """
            SELECT id FROM contents WHERE normalized_hash = ? AND id != ?
            ORDER BY id LIMIT ?
            """,
            [.text(analysis.normalizedHash), .int(contentID), .int(Int64(duplicates.maximumLinks))]
        ) {
            DuplicateLink(
                contentID: contentID, relatedID: $0.int(0), kind: .normalized, distance: 0)
        }

        if let fingerprint = analysis.fingerprint {
            let known = Set(links.map(\.relatedID))
            var near: [DuplicateLink] = []
            var seen = known
            for (band, value) in FingerprintBands.values(of: fingerprint).enumerated() {
                let candidates = try connection.query(
                    """
                    SELECT c.id, c.simhash FROM content_bands b
                    JOIN contents c ON c.id = b.content_id
                    WHERE b.band = ? AND b.value = ? AND c.id != ? LIMIT 500
                    """,
                    [.int(Int64(band)), .int(value), .int(contentID)]
                ) { (id: $0.int(0), hash: UInt64(bitPattern: $0.int(1))) }
                for candidate in candidates where seen.insert(candidate.id).inserted {
                    let distance = SimHash.distance(fingerprint, candidate.hash)
                    if distance <= duplicates.maximumDistance {
                        near.append(
                            DuplicateLink(
                                contentID: contentID, relatedID: candidate.id, kind: .near,
                                distance: distance))
                    }
                }
            }
            near.sort { ($0.distance, $0.relatedID) < ($1.distance, $1.relatedID) }
            links += near
            for (band, value) in FingerprintBands.values(of: fingerprint).enumerated() {
                try connection.execute(
                    "INSERT INTO content_bands (content_id, band, value) VALUES (?, ?, ?)",
                    [.int(contentID), .int(Int64(band)), .int(value)])
            }
        }

        for link in links.prefix(duplicates.maximumLinks) {
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

    /// Links in both directions: contents this one resembles and contents that resemble it.
    public func duplicateLinks(of contentID: Int64) throws -> [DuplicateLink] {
        try database.read { connection in
            try connection.query(
                """
                SELECT content_id, related_id, kind, distance FROM content_links
                WHERE content_id = ?1 OR related_id = ?1
                ORDER BY distance, content_id, related_id
                """,
                [.int(contentID)]
            ) {
                DuplicateLink(
                    contentID: $0.int(0), relatedID: $0.int(1),
                    kind: DuplicateKind(rawValue: $0.text(2)) ?? .near, distance: Int($0.int(3)))
            }
        }
    }
}

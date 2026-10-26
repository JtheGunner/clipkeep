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

    public init(database: Database) {
        self.database = database
    }

    public func record(
        text: String, copiedAt: Date = Date(), context: CopyContext = CopyContext()
    ) throws -> RecordedCopy {
        let hash = ContentHashing.exactHash(text)
        return try database.write { connection in
            let existing = try connection.query(
                "SELECT id FROM contents WHERE hash = ?", [.text(hash)]
            ) { $0.int(0) }

            let contentID: Int64
            let isNew = existing.isEmpty
            if let id = existing.first {
                contentID = id
            } else {
                try connection.execute(
                    """
                    INSERT INTO contents
                        (hash, normalized_hash, text, search_text, kind, first_seen_at, last_copied_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(hash), .text(ContentHashing.normalizedHash(text)), .text(text),
                        .text(SearchText.fold(text)),
                        .text(ContentClassifier.classify(text).rawValue),
                        SQLValue(copiedAt), SQLValue(copiedAt),
                    ])
                contentID = connection.lastInsertRowID
                for entity in EntityExtractor.extract(from: text) {
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
}

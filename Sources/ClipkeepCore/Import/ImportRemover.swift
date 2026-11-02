import Foundation

/// One imported file as the removal dialog lists it.
public struct ImportedSource: Sendable, Equatable {
    public let source: String
    /// Entries that exist only because of this import.
    public let entryCount: Int
    public let firstEntryAt: Date
    public let lastEntryAt: Date
}

/// Takes back a text import. An import tags its copies with the import source and the file name;
/// removing it hides the entries that came only from that file. An entry that also exists from
/// a live copy or another import stays. Hidden entries are purged by the usual upkeep after the
/// undo window, and `restore` brings them back before that.
public struct ImportRemover: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Imported files that still have visible entries, the most recently imported first.
    public func imports() throws -> [ImportedSource] {
        try database.read { connection in
            try connection.query(
                """
                SELECT e.window_title, count(DISTINCT c.id), min(e.copied_at), max(e.copied_at)
                FROM copy_events e JOIN contents c ON c.id = e.content_id
                WHERE e.app_bundle_id = ?1 AND e.window_title IS NOT NULL
                    AND c.deleted_at IS NULL AND \(Self.onlyFromImport("e.window_title"))
                GROUP BY e.window_title
                ORDER BY max(e.id) DESC
                """, [.text(TextImporter.importBundleID)]
            ) {
                ImportedSource(
                    source: $0.text(0), entryCount: Int($0.int(1)),
                    firstEntryAt: Date(timeIntervalSince1970: $0.double(2)),
                    lastEntryAt: Date(timeIntervalSince1970: $0.double(3)))
            }
        }
    }

    /// Hides the entries that came only from `source`. Returns their ids for `restore`.
    @discardableResult
    public func remove(source: String, now: Date = Date()) throws -> [Int64] {
        try database.write { connection in
            let ids = try connection.query(
                """
                SELECT DISTINCT c.id FROM contents c JOIN copy_events e ON e.content_id = c.id
                WHERE e.app_bundle_id = ?1 AND e.window_title = ?2 AND c.deleted_at IS NULL
                    AND \(Self.onlyFromImport("?2"))
                ORDER BY c.id
                """, [.text(TextImporter.importBundleID), .text(source)]
            ) { $0.int(0) }
            for id in ids {
                try connection.execute(
                    "UPDATE contents SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                    [SQLValue(now), .int(id)])
            }
            return ids
        }
    }

    /// Undoes `remove` for the given ids.
    public func restore(_ ids: [Int64]) throws {
        try database.write { connection in
            for id in ids {
                try connection.execute(
                    "UPDATE contents SET deleted_at = NULL WHERE id = ? AND deleted_at IS NOT NULL",
                    [.int(id)])
            }
        }
    }

    /// True for a content whose every copy came from the import of `title`.
    private static func onlyFromImport(_ title: String) -> String {
        """
        NOT EXISTS (
            SELECT 1 FROM copy_events other
            WHERE other.content_id = c.id
                AND NOT (other.app_bundle_id = ?1 AND other.window_title = \(title)))
        """
    }
}

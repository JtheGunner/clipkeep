import Foundation

/// The Swift part of schema version 13: turns every stored snippet into one variant, computes
/// the shape keys and merges snippets that share a language and shape. It runs inside the
/// migration's transaction, after its statements.
enum SnippetShapeMigration {
    private struct StoredSnippet {
        let id: Int64
        let language: String
        let text: String
        let origin: SnippetOrigin
        let comment: String?
        let createdAt: Double
        let lastCopiedAt: Double
        var shapeHash = ""
    }

    @Sendable static func run(_ connection: Connection) throws {
        try connection.execute(
            """
            INSERT INTO snippet_variants
                (snippet_id, text, hash, origin, app_name, created_at, last_copied_at,
                 copy_count)
            SELECT snippet_id, text, hash, origin, app_name, created_at, last_copied_at,
                copy_count
            FROM snippet_variant_seed ORDER BY snippet_id
            """)
        try connection.execute("DROP TABLE snippet_variant_seed")

        let snippets = try storedSnippets(connection)
        for snippet in snippets {
            try connection.execute(
                "UPDATE snippets SET shape_hash = ?, shape_version = ? WHERE id = ?",
                [.text(snippet.shapeHash), .int(Int64(SnippetShape.version)), .int(snippet.id)])
        }

        let groups = Dictionary(grouping: snippets) { "\($0.language)\u{0}\($0.shapeHash)" }
        for group in groups.values where group.count > 1 {
            try merge(group, connection)
        }

        let remaining = try connection.query("SELECT id FROM snippets") { $0.int(0) }
        for id in remaining {
            try SnippetStore.refreshAggregates(connection, snippetID: id)
        }
    }

    private static func storedSnippets(_ connection: Connection) throws -> [StoredSnippet] {
        try connection.query(
            """
            SELECT id, language, text, origin, comment, created_at, last_copied_at
            FROM snippets ORDER BY id
            """
        ) { row in
            let language = row.text(1)
            let text = row.text(2)
            return StoredSnippet(
                id: row.int(0), language: language, text: text,
                origin: SnippetOrigin(rawValue: row.text(3)) ?? .auto,
                comment: row.optionalText(4), createdAt: row.double(5),
                lastCopiedAt: row.double(6),
                shapeHash: SnippetShape.hash(
                    of: text, language: SnippetLanguage(rawValue: language) ?? .shell))
        }
    }

    /// Keeps the most recently copied snippet, so its app stays the representative's app, and
    /// moves the variants of the others to it. The strongest origin, the longest non-empty
    /// comment and the earliest creation time win; counts are summed by the refresh afterwards.
    private static func merge(_ group: [StoredSnippet], _ connection: Connection) throws {
        guard
            let keeper = group.max(by: {
                ($0.lastCopiedAt, $0.id) < ($1.lastCopiedAt, $1.id)
            }),
            let origin = group.map(\.origin).max(by: { $0.priority < $1.priority }),
            let createdAt = group.map(\.createdAt).min()
        else { return }
        let comment = group.compactMap(\.comment).filter { !$0.isEmpty }
            .max { $0.count < $1.count }

        for other in group where other.id != keeper.id {
            try connection.execute(
                "UPDATE snippet_variants SET snippet_id = ? WHERE snippet_id = ?",
                [.int(keeper.id), .int(other.id)])
            try connection.execute("DELETE FROM snippets WHERE id = ?", [.int(other.id)])
        }
        try connection.execute(
            "UPDATE snippets SET origin = ?, comment = ?, created_at = ? WHERE id = ?",
            [.text(origin.rawValue), SQLValue(comment), .double(createdAt), .int(keeper.id)])
    }
}

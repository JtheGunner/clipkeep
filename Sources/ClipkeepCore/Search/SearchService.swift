import Foundation

/// Searches stored contents. Terms of three or more characters use the trigram index and rank
/// by BM25; shorter terms fall back to a substring test. Without a query, the newest items win.
public struct SearchService: Sendable {
    private static let trigramMinimum = 3
    /// How many BM25 points a fully important item gains over an unimportant one.
    private static let importanceBoost = 2.0
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func search(_ query: String, filter: SearchFilter = SearchFilter()) throws -> [SearchHit]
    {
        guard filter.limit > 0 else { return [] }

        // NUL would end an FTS5 string early; treating it as a separator keeps the query valid.
        let folded = SearchText.fold(query.replacingOccurrences(of: "\u{0}", with: " "))
        let terms = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        let indexed = terms.filter { $0.count >= Self.trigramMinimum }
        let short = terms.filter { $0.count < Self.trigramMinimum }

        // Rank, filter and limit first, then look up the details of the surviving rows only.
        // BM25 is negative (lower is better); the importance boost pulls important items forward.
        // Without an indexed term the listing orders by importance, which has its own index.
        var inner = "SELECT c.id, c.text, c.kind, c.last_copied_at, c.importance, "
        inner +=
            indexed.isEmpty
            ? "0.0 AS score\nFROM contents c"
            : "bm25(contents_fts) - \(Self.importanceBoost) * c.importance AS score\nFROM contents c"
        var parameters: [SQLValue] = []

        if !indexed.isEmpty {
            inner += "\nJOIN contents_fts ON contents_fts.rowid = c.id AND contents_fts MATCH ?"
            parameters.append(.text(indexed.map(Self.quoted).joined(separator: " ")))
        }

        var conditions: [String] = []
        for term in short {
            conditions.append("instr(c.search_text, ?) > 0")
            parameters.append(.text(term))
        }
        if let kind = filter.kind {
            conditions.append("c.kind = ?")
            parameters.append(.text(kind))
        }

        var eventConditions: [String] = []
        if let appBundleID = filter.appBundleID {
            eventConditions.append("e.app_bundle_id = ?")
            parameters.append(.text(appBundleID))
        }
        if let after = filter.copiedAfter {
            eventConditions.append("e.copied_at >= ?")
            parameters.append(SQLValue(after))
        }
        if let before = filter.copiedBefore {
            eventConditions.append("e.copied_at < ?")
            parameters.append(SQLValue(before))
        }
        if let sessionID = filter.sessionID {
            eventConditions.append("e.session_id = ?")
            parameters.append(.int(sessionID))
        }
        if !eventConditions.isEmpty {
            conditions.append(
                "EXISTS (SELECT 1 FROM copy_events e WHERE e.content_id = c.id AND "
                    + eventConditions.joined(separator: " AND ") + ")")
        }

        if !conditions.isEmpty { inner += "\nWHERE " + conditions.joined(separator: " AND ") }
        let order =
            indexed.isEmpty
            ? "importance DESC, last_copied_at DESC, id DESC"
            : "score, last_copied_at DESC, id DESC"
        inner += "\nORDER BY \(order)\nLIMIT ?"
        parameters.append(.int(Int64(filter.limit)))

        let sql = """
            WITH page AS (\(inner))
            SELECT page.id, page.text, page.kind, page.last_copied_at,
                (SELECT count(*) FROM copy_events WHERE content_id = page.id),
                (SELECT app_name FROM copy_events WHERE content_id = page.id
                    ORDER BY copied_at DESC, id DESC LIMIT 1),
                (SELECT window_title FROM copy_events WHERE content_id = page.id
                    ORDER BY copied_at DESC, id DESC LIMIT 1),
                (SELECT url FROM copy_events WHERE content_id = page.id
                    ORDER BY copied_at DESC, id DESC LIMIT 1)
            FROM page
            ORDER BY \(order)
            """

        return try database.read { connection in
            try connection.query(sql, parameters) { row in
                SearchHit(
                    contentID: row.int(0), text: row.text(1), kind: row.text(2),
                    lastCopiedAt: Date(timeIntervalSince1970: row.double(3)),
                    occurrenceCount: Int(row.int(4)), lastAppName: row.optionalText(5),
                    lastWindowTitle: row.optionalText(6), lastURL: row.optionalText(7))
            }
        }
    }

    /// Wraps a term as an FTS5 string so operators and punctuation in the query stay literal.
    private static func quoted(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

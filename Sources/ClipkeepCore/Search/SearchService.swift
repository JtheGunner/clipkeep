import Foundation

/// Searches stored contents. Terms of three or more characters use the trigram index and rank
/// by BM25 scaled by importance; shorter terms fall back to a substring test. Without a query the
/// listing is newest first, or by importance on request.
public struct SearchService: Sendable {
    private static let trigramMinimum = 3
    /// A fully important item scores this much better than an unimportant one with the same BM25.
    /// Multiplying keeps the boost proportional to relevance: it reorders close matches but a
    /// clearly better match still wins, and terms without any relevance signal stay unaffected.
    private static let importanceBoost = 0.5
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
        // BM25 is negative (lower is better), so scaling it up pulls important items forward.
        var inner = "SELECT c.id, c.text, c.kind, c.last_copied_at, c.importance, "
        inner +=
            indexed.isEmpty
            ? "0.0 AS score\nFROM contents c"
            : "bm25(contents_fts) * (1.0 + \(Self.importanceBoost) * c.importance) AS score\nFROM contents c"
        var parameters: [SQLValue] = []

        if !indexed.isEmpty {
            inner += "\nJOIN contents_fts ON contents_fts.rowid = c.id AND contents_fts MATCH ?"
            parameters.append(.text(indexed.map(Self.quoted).joined(separator: " ")))
        }

        // Deleted items stay hidden until restored.
        var conditions: [String] = ["c.deleted_at IS NULL"]
        for term in short {
            conditions.append("instr(c.search_text, ?) > 0")
            parameters.append(.text(term))
        }
        if let kind = filter.kind {
            conditions.append("c.kind = ?")
            parameters.append(.text(kind))
        }

        if let excluded = filter.excludedKind {
            conditions.append("c.kind != ?")
            parameters.append(.text(excluded))
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
            indexed.isEmpty && filter.listingOrder == .importance
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

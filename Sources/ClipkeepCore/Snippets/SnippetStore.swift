import Foundation

public enum SnippetLanguage: String, Sendable, CaseIterable {
    case shell
    case sql
    case yaml
}

public enum SnippetOrigin: String, Sendable {
    /// Captured automatically from the clipboard.
    case auto
    /// Promoted by hand from the clipboard history.
    case history
    /// Written or pasted by the user in the explorer.
    case manual

    /// When snippets merge, the origin with the higher priority wins.
    public var priority: Int {
        switch self {
        case .manual: 2
        case .history: 1
        case .auto: 0
        }
    }
}

/// A snippet with all the variants that share its shape. `text` and `appName` are those of the
/// representative variant, the most recently copied one; `copyCount` is the sum over the
/// variants and `lastCopiedAt` the latest of them.
public struct Snippet: Sendable, Equatable {
    public let id: Int64
    public let text: String
    public let language: SnippetLanguage
    public let origin: SnippetOrigin
    public let appName: String?
    public let createdAt: Date
    public let lastCopiedAt: Date
    public let copyCount: Int
    public let comment: String?
    public let variantCount: Int
    public let shapeHash: String
    /// The folded text of every variant and the comment, as indexed for search.
    public let searchText: String
}

/// One exact text of a snippet.
public struct SnippetVariant: Sendable, Equatable {
    public let id: Int64
    public let snippetID: Int64
    public let text: String
    public let createdAt: Date
    public let lastCopiedAt: Date
    public let copyCount: Int
}

public enum SnippetAddOutcome: Sendable, Equatable {
    /// A new snippet was stored.
    case inserted(Int64)
    /// The text joined the snippet with this id, as a new variant or as another copy of one.
    case bumped(Int64)
    /// The snippet with this id was not counted again, because bumping was not asked for.
    case unchanged(Int64)
    /// The user deleted this text before, so it is not stored again unless overridden.
    case rejected
}

/// The snippet collection. It is independent of the clipboard history tables, so history
/// maintenance never reads or changes it. Texts with the same language and shape (see
/// `SnippetShape`) are variants of one snippet.
public struct SnippetStore: Sendable {
    private static let trigramMinimum = 3
    /// Longest stored comment, in characters.
    private static let maxCommentLength = 2000
    private static let qualifiedColumns = """
        s.id, s.text, s.language, s.origin, s.app_name, s.created_at, s.last_copied_at, \
        s.copy_count, s.comment, \
        (SELECT count(*) FROM snippet_variants v WHERE v.snippet_id = s.id), \
        s.shape_hash, s.search_text
        """
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Stores `text` as a new snippet, as a new variant of the snippet with the same shape, or
    /// as another copy of the same variant. A text the user deleted is rejected unless
    /// `overridingRejection` is set, which clears the rejection first. Without
    /// `bumpingExisting`, nothing counts as another copy: a known text is left as it is and a
    /// new variant is added with no copies, both reported as `unchanged`. A `manual` add raises
    /// the origin of the snippet it joins.
    public func add(
        text: String, language: SnippetLanguage, origin: SnippetOrigin, appName: String?,
        overridingRejection: Bool = false, bumpingExisting: Bool = true, at date: Date = Date()
    ) throws -> SnippetAddOutcome {
        let hash = ContentHashing.exactHash(text)
        return try database.write { connection in
            if overridingRejection {
                try connection.execute(
                    "DELETE FROM snippet_rejections WHERE hash = ?", [.text(hash)])
            } else {
                let rejected = try connection.query(
                    "SELECT 1 FROM snippet_rejections WHERE hash = ?", [.text(hash)]
                ) { $0.int(0) }
                if !rejected.isEmpty { return .rejected }
            }

            let variants = try connection.query(
                "SELECT id, snippet_id FROM snippet_variants WHERE hash = ?", [.text(hash)]
            ) { ($0.int(0), $0.int(1)) }
            if let (variantID, snippetID) = variants.first {
                try raiseOrigin(connection, snippetID: snippetID, to: origin)
                guard bumpingExisting else { return .unchanged(snippetID) }
                try connection.execute(
                    """
                    UPDATE snippet_variants
                    SET copy_count = copy_count + 1, last_copied_at = max(last_copied_at, ?)
                    WHERE id = ?
                    """, [SQLValue(date), .int(variantID)])
                try Self.refreshAggregates(connection, snippetID: snippetID)
                return .bumped(snippetID)
            }

            let shapeHash = SnippetShape.hash(of: text, language: language)
            let shapes = try connection.query(
                "SELECT id FROM snippets WHERE language = ? AND shape_hash = ? ORDER BY id LIMIT 1",
                [.text(language.rawValue), .text(shapeHash)]
            ) { $0.int(0) }
            if let snippetID = shapes.first {
                try insertVariant(
                    connection, snippetID: snippetID, text: text, hash: hash, appName: appName,
                    copyCount: bumpingExisting ? 1 : 0, at: date)
                try raiseOrigin(connection, snippetID: snippetID, to: origin)
                try Self.refreshAggregates(connection, snippetID: snippetID)
                return bumpingExisting ? .bumped(snippetID) : .unchanged(snippetID)
            }

            try connection.execute(
                """
                INSERT INTO snippets
                    (text, language, origin, app_name, search_text, created_at, last_copied_at,
                     copy_count, shape_hash, shape_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                [
                    .text(text), .text(language.rawValue), .text(origin.rawValue),
                    SQLValue(appName), .text(SearchText.fold(text)), SQLValue(date),
                    SQLValue(date), .text(shapeHash), .int(Int64(SnippetShape.version)),
                ])
            let snippetID = connection.lastInsertRowID
            try insertVariant(
                connection, snippetID: snippetID, text: text, hash: hash, appName: appName,
                copyCount: 1, at: date)
            try Self.refreshAggregates(connection, snippetID: snippetID)
            return .inserted(snippetID)
        }
    }

    /// Snippets, newest first.
    public func list(limit: Int) throws -> [Snippet] {
        guard limit > 0 else { return [] }
        return try database.read { connection in
            try connection.query(
                """
                SELECT \(Self.qualifiedColumns) FROM snippets s
                ORDER BY s.last_copied_at DESC, s.id DESC LIMIT ?
                """, [.int(Int64(limit))], map: Self.snippet)
        }
    }

    /// The snippet with this id, or nil when it does not exist.
    public func snippet(id: Int64) throws -> Snippet? {
        try database.read { connection in
            try connection.query(
                "SELECT \(Self.qualifiedColumns) FROM snippets s WHERE s.id = ?", [.int(id)],
                map: Self.snippet
            ).first
        }
    }

    /// Terms of three or more characters use the trigram index and rank by BM25, then copy
    /// count, then recency. Shorter terms fall back to a substring test. An empty query lists.
    /// Every variant and the comment are searched; each snippet appears once.
    public func search(_ query: String, limit: Int) throws -> [Snippet] {
        guard limit > 0 else { return [] }

        // NUL would end an FTS5 string early; treating it as a separator keeps the query valid.
        let folded = SearchText.fold(query.replacingOccurrences(of: "\u{0}", with: " "))
        let terms = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty { return try list(limit: limit) }
        let indexed = terms.filter { $0.count >= Self.trigramMinimum }
        let short = terms.filter { $0.count < Self.trigramMinimum }

        var sql = "SELECT \(Self.qualifiedColumns) FROM snippets s"
        var parameters: [SQLValue] = []
        if !indexed.isEmpty {
            sql += "\nJOIN snippets_fts ON snippets_fts.rowid = s.id AND snippets_fts MATCH ?"
            parameters.append(.text(indexed.map(Self.quoted).joined(separator: " ")))
        }
        var conditions: [String] = []
        for term in short {
            conditions.append("instr(s.search_text, ?) > 0")
            parameters.append(.text(term))
        }
        if !conditions.isEmpty { sql += "\nWHERE " + conditions.joined(separator: " AND ") }
        sql +=
            indexed.isEmpty
            ? "\nORDER BY s.copy_count DESC, s.last_copied_at DESC, s.id DESC LIMIT ?"
            : "\nORDER BY bm25(snippets_fts), s.copy_count DESC, s.last_copied_at DESC, s.id DESC LIMIT ?"
        parameters.append(.int(Int64(limit)))

        return try database.read { connection in
            try connection.query(sql, parameters, map: Self.snippet)
        }
    }

    /// The variants of one snippet, most recently copied first.
    public func variants(of snippetID: Int64) throws -> [SnippetVariant] {
        try database.read { connection in
            try connection.query(
                """
                SELECT id, snippet_id, text, created_at, last_copied_at, copy_count
                FROM snippet_variants WHERE snippet_id = ?
                ORDER BY last_copied_at DESC, id DESC
                """, [.int(snippetID)]
            ) { row in
                SnippetVariant(
                    id: row.int(0), snippetID: row.int(1), text: row.text(2),
                    createdAt: Date(timeIntervalSince1970: row.double(3)),
                    lastCopiedAt: Date(timeIntervalSince1970: row.double(4)),
                    copyCount: Int(row.int(5)))
            }
        }
    }

    /// Removes the snippet with all its variants and remembers every variant's text so none is
    /// captured again. Returns whether a snippet with this id existed.
    public func delete(id: Int64) throws -> Bool {
        try database.write { connection in
            let exists = try connection.query(
                "SELECT 1 FROM snippets WHERE id = ?", [.int(id)]
            ) { $0.int(0) }
            guard !exists.isEmpty else { return false }
            try connection.execute(
                """
                INSERT OR IGNORE INTO snippet_rejections(hash)
                SELECT hash FROM snippet_variants WHERE snippet_id = ?
                """, [.int(id)])
            try connection.execute("DELETE FROM snippets WHERE id = ?", [.int(id)])
            return true
        }
    }

    /// The comment as stored: trimmed, nil when empty, cut off after `maxCommentLength`
    /// characters.
    static func storedComment(_ comment: String?) -> String? {
        // Trim again after the cut so it never leaves trailing whitespace behind.
        comment.flatMap { text -> String? in
            let cut = String(
                text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCommentLength)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return cut.isEmpty ? nil : cut
        }
    }

    /// Sets or clears the free-text comment of a snippet, stored as `storedComment` gives it.
    /// Returns whether a snippet with this id existed. Internal on purpose: the app writes
    /// comments through `SnippetCreator.setComment`, which anonymises them first.
    func setComment(id: Int64, comment: String?) throws -> Bool {
        let stored = Self.storedComment(comment)
        return try database.write { connection in
            let exists = try connection.query(
                "SELECT 1 FROM snippets WHERE id = ?", [.int(id)]
            ) { $0.int(0) }
            guard !exists.isEmpty else { return false }
            try connection.execute(
                "UPDATE snippets SET comment = ? WHERE id = ?", [SQLValue(stored), .int(id)])
            try Self.refreshAggregates(connection, snippetID: id)
            return true
        }
    }

    public func count() throws -> Int {
        try database.read { connection in
            try connection.query("SELECT count(*) FROM snippets") { Int($0.int(0)) }.first ?? 0
        }
    }

    /// Recomputes what a snippet keeps of its variants: the representative (most recently
    /// copied) variant with its text and app, the summed count, the latest copy time and the
    /// search text over every variant and the comment. Call it after any variant or comment
    /// change, inside the same transaction. Migration 13 reuses it on databases that have not
    /// migrated yet, so a change to what it computes also changes that migration.
    static func refreshAggregates(_ connection: Connection, snippetID: Int64) throws {
        let variants = try connection.query(
            """
            SELECT id, text, app_name, last_copied_at, copy_count FROM snippet_variants
            WHERE snippet_id = ? ORDER BY last_copied_at DESC, id DESC
            """, [.int(snippetID)]
        ) { row in
            (
                id: row.int(0), text: row.text(1), appName: row.optionalText(2),
                lastCopiedAt: row.double(3), copyCount: row.int(4)
            )
        }
        guard let representative = variants.first else { return }
        let comment =
            try connection.query(
                "SELECT comment FROM snippets WHERE id = ?", [.int(snippetID)]
            ) { $0.optionalText(0) }.first ?? nil
        let searchText = SearchText.fold(
            (variants.map(\.text) + [comment].compactMap { $0 }).joined(separator: "\n"))
        try connection.execute(
            """
            UPDATE snippets
            SET text = ?, app_name = ?, copy_count = ?, last_copied_at = ?,
                representative_variant_id = ?, search_text = ?
            WHERE id = ?
            """,
            [
                .text(representative.text), SQLValue(representative.appName),
                .int(variants.reduce(0) { $0 + $1.copyCount }),
                .double(representative.lastCopiedAt), .int(representative.id),
                .text(searchText), .int(snippetID),
            ])
    }

    private func insertVariant(
        _ connection: Connection, snippetID: Int64, text: String, hash: String,
        appName: String?, copyCount: Int64, at date: Date
    ) throws {
        try connection.execute(
            """
            INSERT INTO snippet_variants
                (snippet_id, text, hash, app_name, created_at, last_copied_at, copy_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(snippetID), .text(text), .text(hash), SQLValue(appName), SQLValue(date),
                SQLValue(date), .int(copyCount),
            ])
    }

    /// Only a manual add raises the origin; capture and promotion leave it as it is.
    private func raiseOrigin(
        _ connection: Connection, snippetID: Int64, to origin: SnippetOrigin
    ) throws {
        guard origin == .manual else { return }
        try connection.execute(
            "UPDATE snippets SET origin = ? WHERE id = ?",
            [.text(origin.rawValue), .int(snippetID)])
    }

    private static func snippet(_ row: Row) -> Snippet {
        Snippet(
            id: row.int(0), text: row.text(1),
            language: SnippetLanguage(rawValue: row.text(2)) ?? .shell,
            origin: SnippetOrigin(rawValue: row.text(3)) ?? .auto, appName: row.optionalText(4),
            createdAt: Date(timeIntervalSince1970: row.double(5)),
            lastCopiedAt: Date(timeIntervalSince1970: row.double(6)), copyCount: Int(row.int(7)),
            comment: row.optionalText(8), variantCount: Int(row.int(9)),
            shapeHash: row.text(10), searchText: row.text(11))
    }

    /// Wraps a term as an FTS5 string so operators and punctuation in the query stay literal.
    private static func quoted(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

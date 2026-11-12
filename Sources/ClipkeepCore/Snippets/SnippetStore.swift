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
}

public struct Snippet: Sendable, Equatable {
    public let id: Int64
    public let text: String
    public let language: SnippetLanguage
    public let origin: SnippetOrigin
    public let appName: String?
    public let createdAt: Date
    public let lastCopiedAt: Date
    public let copyCount: Int
}

public enum SnippetAddOutcome: Sendable, Equatable {
    case inserted(Int64)
    /// The text was already stored; its copy count and last-copied time were updated.
    case bumped(Int64)
    /// The text was already stored and was left as it is, because bumping was not asked for.
    case unchanged(Int64)
    /// The user deleted this text before, so it is not stored again unless overridden.
    case rejected
}

/// The snippet collection. It is independent of the clipboard history tables, so history
/// maintenance never reads or changes it.
public struct SnippetStore: Sendable {
    private static let trigramMinimum = 3
    private static let columns =
        "id, text, language, origin, app_name, created_at, last_copied_at, copy_count"
    private static let qualifiedColumns =
        "s.id, s.text, s.language, s.origin, s.app_name, s.created_at, s.last_copied_at, s.copy_count"
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Stores `text`, or bumps the existing row with the same text. A text the user deleted is
    /// rejected unless `overridingRejection` is set, which clears the rejection first. Without
    /// `bumpingExisting`, a stored text is left unchanged instead of counting as another copy.
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

            let existing = try connection.query(
                "SELECT id FROM snippets WHERE hash = ?", [.text(hash)]
            ) { $0.int(0) }
            if let id = existing.first {
                guard bumpingExisting else { return .unchanged(id) }
                try connection.execute(
                    """
                    UPDATE snippets
                    SET copy_count = copy_count + 1, last_copied_at = max(last_copied_at, ?)
                    WHERE id = ?
                    """, [SQLValue(date), .int(id)])
                return .bumped(id)
            }

            try connection.execute(
                """
                INSERT INTO snippets
                    (text, hash, language, origin, app_name, search_text, created_at,
                     last_copied_at, copy_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
                [
                    .text(text), .text(hash), .text(language.rawValue), .text(origin.rawValue),
                    SQLValue(appName), .text(SearchText.fold(text)), SQLValue(date),
                    SQLValue(date),
                ])
            return .inserted(connection.lastInsertRowID)
        }
    }

    /// Snippets, newest first.
    public func list(limit: Int) throws -> [Snippet] {
        guard limit > 0 else { return [] }
        return try database.read { connection in
            try connection.query(
                """
                SELECT \(Self.columns) FROM snippets
                ORDER BY last_copied_at DESC, id DESC LIMIT ?
                """, [.int(Int64(limit))], map: Self.snippet)
        }
    }

    /// Terms of three or more characters use the trigram index and rank by BM25, then copy
    /// count, then recency. Shorter terms fall back to a substring test. An empty query lists.
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

    /// Removes the snippet and remembers its text so it is not captured again.
    /// Returns whether a snippet with this id existed.
    public func delete(id: Int64) throws -> Bool {
        try database.write { connection in
            let hashes = try connection.query(
                "SELECT hash FROM snippets WHERE id = ?", [.int(id)]
            ) { $0.text(0) }
            guard let hash = hashes.first else { return false }
            try connection.execute("DELETE FROM snippets WHERE id = ?", [.int(id)])
            try connection.execute(
                "INSERT OR IGNORE INTO snippet_rejections(hash) VALUES (?)", [.text(hash)])
            return true
        }
    }

    public func count() throws -> Int {
        try database.read { connection in
            try connection.query("SELECT count(*) FROM snippets") { Int($0.int(0)) }.first ?? 0
        }
    }

    private static func snippet(_ row: Row) -> Snippet {
        Snippet(
            id: row.int(0), text: row.text(1),
            language: SnippetLanguage(rawValue: row.text(2)) ?? .shell,
            origin: SnippetOrigin(rawValue: row.text(3)) ?? .auto, appName: row.optionalText(4),
            createdAt: Date(timeIntervalSince1970: row.double(5)),
            lastCopiedAt: Date(timeIntervalSince1970: row.double(6)), copyCount: Int(row.int(7)))
    }

    /// Wraps a term as an FTS5 string so operators and punctuation in the query stay literal.
    private static func quoted(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

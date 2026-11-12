import Foundation

public enum PromotionOutcome: Sendable, Equatable {
    /// The snippet was stored, or an existing one with the same text was bumped.
    case stored(Int64)
    /// The filter does not recognise a language; the caller has to supply one.
    case needsLanguage
    /// The entry is deleted, a parked secret's placeholder or does not exist.
    case unavailable
    /// The text is far larger than a snippet; nothing was stored.
    case tooLarge
    /// The anonymised text still contained something the detector flags; nothing was stored.
    case residualSecret
}

public struct BackfillReport: Sendable, Equatable {
    /// History entries read: neither deleted nor a parked secret.
    public let examined: Int
    /// Snippets that did not exist before.
    public let added: Int

    public init(examined: Int, added: Int) {
        self.examined = examined
        self.added = added
    }
}

/// Turns clipboard history entries into snippets: one entry on request, or the whole history
/// once to seed the collection. It only reads the history and never changes it.
public struct SnippetPromoter: Sendable {
    public static let defaultPageSize = 500

    private let database: Database
    private let store: SnippetStore
    private let anonymizer: SnippetAnonymizer
    private let residualDetector: SecretDetector
    private let pageSize: Int

    public init(
        database: Database, store: SnippetStore,
        anonymizer: SnippetAnonymizer = SnippetAnonymizer(),
        residualDetector: SecretDetector = SecretDetector(),
        pageSize: Int = SnippetPromoter.defaultPageSize
    ) {
        self.database = database
        self.store = store
        self.anonymizer = anonymizer
        self.residualDetector = residualDetector
        self.pageSize = max(1, pageSize)
    }

    /// Texts above this many bytes are not read into a snippet at all, as in live capture.
    private static var maximumSourceBytes: Int {
        SnippetFilter.Threshold.maximumBytes * SnippetCapture.sizeSlackFactor
    }

    /// Stores one history entry as a snippet. The filter's strictness does not apply, but the
    /// text is always anonymised first and a matching rejection is cleared. The language is
    /// `language` when given, otherwise the one the filter recognises.
    public func promote(contentID: Int64, language: SnippetLanguage?) throws -> PromotionOutcome {
        let texts = try database.read { connection in
            try connection.query(
                """
                SELECT text FROM contents
                WHERE id = ? AND deleted_at IS NULL AND kind != ?
                """, [.int(contentID), .text(ContentKind.secret.rawValue)]
            ) { $0.text(0) }
        }
        guard let original = texts.first else { return .unavailable }
        guard original.utf8.count <= Self.maximumSourceBytes else { return .tooLarge }

        let anonymised = anonymizer.anonymize(original)
        guard anonymised.utf8.count <= SnippetFilter.Threshold.maximumBytes else {
            return .tooLarge
        }
        // Fail closed, as in live capture: a secret left after anonymising is never stored.
        guard !residualDetector.containsSecret(in: anonymised) else { return .residualSecret }
        guard let chosen = language ?? SnippetFilter.evaluate(anonymised) else {
            return .needsLanguage
        }

        switch try store.add(
            text: anonymised, language: chosen, origin: .history, appName: nil,
            overridingRejection: true)
        {
        case .inserted(let id), .bumped(let id), .unchanged(let id): return .stored(id)
        // Cannot happen while the rejection is overridden; treated like a vanished entry.
        case .rejected: return .unavailable
        }
    }

    /// Seeds the collection from the history with the same anonymiser and filter as live
    /// capture. Deleted snippets stay deleted, and a snippet that already exists is left as it
    /// is, so running it again adds nothing and inflates no copy count. Parked secrets are never
    /// read. The history is read in pages, so memory stays bounded on a large history.
    public func backfill() throws -> BackfillReport {
        var examined = 0
        var added = 0
        var lastID: Int64 = 0
        while true {
            let page = try readPage(after: lastID)
            for entry in page {
                examined += 1
                if try backfill(entry) { added += 1 }
            }
            guard page.count == pageSize, let last = page.last else { break }
            lastID = last.id
        }
        return BackfillReport(examined: examined, added: added)
    }

    private struct HistoryEntry {
        let id: Int64
        /// Nil when the text is far above the snippet size; it is then not loaded at all.
        let text: String?
        let lastCopiedAt: Date
    }

    private func readPage(after lastID: Int64) throws -> [HistoryEntry] {
        try database.read { connection in
            try connection.query(
                """
                SELECT id,
                    CASE WHEN length(CAST(text AS BLOB)) <= ? THEN text END,
                    last_copied_at
                FROM contents
                WHERE deleted_at IS NULL AND kind != ? AND id > ?
                ORDER BY id LIMIT ?
                """,
                [
                    .int(Int64(Self.maximumSourceBytes)), .text(ContentKind.secret.rawValue),
                    .int(lastID), .int(Int64(pageSize)),
                ]
            ) { row in
                HistoryEntry(
                    id: row.int(0), text: row.optionalText(1),
                    lastCopiedAt: Date(timeIntervalSince1970: row.double(2)))
            }
        }
    }

    /// Whether the entry became a new snippet.
    private func backfill(_ entry: HistoryEntry) throws -> Bool {
        guard let original = entry.text else { return false }
        let anonymised = anonymizer.anonymize(original)
        guard let language = SnippetFilter.evaluate(anonymised),
            !residualDetector.containsSecret(in: anonymised)
        else { return false }
        let outcome = try store.add(
            text: anonymised, language: language, origin: .history, appName: nil,
            bumpingExisting: false, at: entry.lastCopiedAt)
        if case .inserted = outcome { return true }
        return false
    }
}

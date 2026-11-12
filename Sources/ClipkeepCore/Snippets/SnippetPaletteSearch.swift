import Foundation

/// The snippet search behind the palette's snippet mode.
public struct SnippetPaletteSearch: PaletteSource {
    private let store: SnippetStore

    public init(store: SnippetStore) {
        self.store = store
    }

    /// An empty query lists the most recently copied snippets; a query ranks by match.
    public func rows(for query: String, now: Date = Date()) throws -> [PaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippets =
            trimmed.isEmpty
            ? try store.list(limit: PaletteSearch.rowLimit)
            : try store.search(trimmed, limit: PaletteSearch.rowLimit)
        return snippets.map { PaletteRow(snippet: $0, now: now) }
    }
}

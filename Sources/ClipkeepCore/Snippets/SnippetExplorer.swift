import Foundation

public enum SnippetSortKey: String, Sendable, CaseIterable {
    case lastUsed
    case created
    case count
    case language
    case topic
    case title
}

/// What the snippet explorer shows: filters and the order. All of it runs in memory over the
/// loaded snippets, so the window answers every keystroke without touching the database.
public struct SnippetExplorerQuery: Sendable, Equatable {
    public var text: String
    public var language: SnippetLanguage?
    public var topic: String?
    public var sortKey: SnippetSortKey
    public var ascending: Bool

    public init(
        text: String = "", language: SnippetLanguage? = nil, topic: String? = nil,
        sortKey: SnippetSortKey = .lastUsed, ascending: Bool = false
    ) {
        self.text = text
        self.language = language
        self.topic = topic
        self.sortKey = sortKey
        self.ascending = ascending
    }
}

public struct SnippetTopicCount: Sendable, Equatable {
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public enum SnippetExplorer {
    /// Filters, then sorts. Ties fall back to the most recently used, so the order is stable.
    public static func apply(_ query: SnippetExplorerQuery, to snippets: [Snippet]) -> [Snippet] {
        let terms = SearchText.fold(query.text).split(whereSeparator: \.isWhitespace)
        let keyed = snippets.compactMap { snippet -> (Snippet, String?)? in
            if let language = query.language, snippet.language != language { return nil }
            let topic = SnippetTopic.of(snippet)
            if let wanted = query.topic, topic != wanted { return nil }
            if !terms.isEmpty {
                let haystack = SearchText.fold(snippet.text + " " + (topic ?? ""))
                guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
            }
            return (snippet, topic)
        }
        return
            keyed
            .sorted { precedes($0, $1, query) }
            .map(\.0)
    }

    /// The topics present, most frequent first, then by name. Snippets without a topic are
    /// left out. With a language, only that language's snippets count.
    public static func topics(in snippets: [Snippet], language: SnippetLanguage?)
        -> [SnippetTopicCount]
    {
        var counts: [String: Int] = [:]
        for snippet in snippets where language == nil || snippet.language == language {
            if let topic = SnippetTopic.of(snippet) { counts[topic, default: 0] += 1 }
        }
        return counts.map { SnippetTopicCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private static func precedes(
        _ lhs: (Snippet, String?), _ rhs: (Snippet, String?), _ query: SnippetExplorerQuery
    ) -> Bool {
        let (a, topicA) = lhs
        let (b, topicB) = rhs
        let order: ComparisonResult
        switch query.sortKey {
        case .lastUsed: order = compare(a.lastCopiedAt, b.lastCopiedAt)
        case .created: order = compare(a.createdAt, b.createdAt)
        case .count: order = compare(a.copyCount, b.copyCount)
        case .language: order = compare(languageRank(a.language), languageRank(b.language))
        case .title:
            order = compare(
                PaletteRow.title(of: a.text).lowercased(), PaletteRow.title(of: b.text).lowercased()
            )
        case .topic:
            // A snippet without a topic goes last in either direction.
            switch (topicA, topicB) {
            case (nil, nil): order = .orderedSame
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?): order = compare(x, y)
            }
        }
        if order != .orderedSame {
            return (order == .orderedAscending) == query.ascending
        }
        if a.lastCopiedAt != b.lastCopiedAt { return a.lastCopiedAt > b.lastCopiedAt }
        return a.id > b.id
    }

    private static func languageRank(_ language: SnippetLanguage) -> Int {
        SnippetLanguage.allCases.firstIndex(of: language) ?? 0
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}

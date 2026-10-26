import Foundation

/// What the history window searches in: everything, or one day, session or topic.
public enum HistoryScope: Sendable, Equatable {
    case all
    case day(Date)
    case session(Int64)
    case topic(Int64)

    public func filter(limit: Int, calendar: Calendar = .current) -> SearchFilter {
        var filter = SearchFilter(limit: limit)
        switch self {
        case .all: break
        case .day(let date):
            let start = calendar.startOfDay(for: date)
            filter.copiedAfter = start
            filter.copiedBefore = calendar.date(byAdding: .day, value: 1, to: start)
        case .session(let id): filter.sessionID = id
        case .topic(let id): filter.topicID = id
        }
        return filter
    }
}

/// One line of an entry list, from a session entry or a search hit.
public struct HistoryRow: Sendable, Equatable {
    public let contentID: Int64
    public let title: String
    private let info: String
    public var subtitle: String {
        info + (isPinned ? " · angeheftet" : "") + (isStarred ? " · markiert" : "")
    }
    public let isPinned: Bool
    public let isStarred: Bool

    /// The same row after a pin or star change.
    public func with(isPinned: Bool, isStarred: Bool) -> HistoryRow {
        HistoryRow(
            contentID: contentID, title: title, info: info, isPinned: isPinned,
            isStarred: isStarred)
    }

    private init(contentID: Int64, title: String, info: String, isPinned: Bool, isStarred: Bool) {
        self.contentID = contentID
        self.title = title
        self.info = info
        self.isPinned = isPinned
        self.isStarred = isStarred
    }

    public init(entry: SessionEntry, format: HistoryFormat) {
        self.init(
            contentID: entry.contentID, text: entry.preview, kind: entry.kind,
            time: format.dateTime(entry.copiedAt), app: entry.appName, isPinned: entry.isPinned,
            isStarred: entry.isStarred)
    }

    public init(hit: SearchHit, format: HistoryFormat) {
        self.init(
            contentID: hit.contentID, text: hit.text, kind: hit.kind,
            time: format.dateTime(hit.lastCopiedAt), app: hit.lastAppName,
            isPinned: hit.isPinned, isStarred: hit.isStarred)
    }

    private init(
        contentID: Int64, text: String, kind: String, time: String, app: String?, isPinned: Bool,
        isStarred: Bool
    ) {
        self.contentID = contentID
        title = PaletteRow.title(of: String(text.prefix(PaletteRow.maximumTitleLength * 4)))
        var parts = [time]
        if let app { parts.append(app) }
        parts.append(PaletteRow.typeName(kind))
        info = parts.joined(separator: " · ")
        self.isPinned = isPinned
        self.isStarred = isStarred
    }
}

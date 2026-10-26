import Foundation

/// The sessions of one calendar day, newest first.
public struct DaySection: Sendable, Equatable {
    /// Midnight of the day in the timeline's calendar.
    public let day: Date
    public fileprivate(set) var sessions: [SessionSummary]
}

/// Sessions grouped by day. Pages arrive newest first (see `HistoryBrowser.sessions`); a page
/// that continues the day of the previous one extends that section instead of opening a new one.
public struct DayTimeline: Sendable {
    public private(set) var sections: [DaySection] = []
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The session to pass as `after` for the next page.
    public var last: SessionSummary? { sections.last?.sessions.last }

    public var sessionCount: Int { sections.reduce(0) { $0 + $1.sessions.count } }

    public mutating func append(_ page: [SessionSummary]) {
        for session in page {
            let day = calendar.startOfDay(for: session.startedAt)
            if sections.last?.day == day {
                sections[sections.count - 1].sessions.append(session)
            } else {
                sections.append(DaySection(day: day, sessions: [session]))
            }
        }
    }
}

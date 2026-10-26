import Foundation

/// Thresholds for cutting the copy stream into sessions.
public struct SessionConfiguration: Sendable, Equatable {
    public static let `default` = SessionConfiguration()

    /// A pause longer than this always starts a new session.
    public let gap: TimeInterval
    /// A change of app after a pause longer than this starts a new session.
    public let appSwitchGap: TimeInterval
    /// A new repo or website must show up in this many consecutive copies before it counts as a
    /// context switch, so a single stray copy does not cut a session in two.
    public let contextConfirmations: Int

    public init(
        gapMinutes: Double = 25, appSwitchGapMinutes: Double = 10, contextConfirmations: Int = 2
    ) {
        gap = max(gapMinutes, 0) * 60
        appSwitchGap = min(max(appSwitchGapMinutes, 0), max(gapMinutes, 0)) * 60
        self.contextConfirmations = max(contextConfirmations, 1)
    }
}

/// One copy as the segmenter sees it.
public struct SessionEvent: Sendable, Equatable {
    public let id: Int64
    public let time: Date
    public let appBundleID: String?
    /// Repo of the copied content, else the website it came from.
    public let context: String?

    public init(id: Int64, time: Date, appBundleID: String? = nil, context: String? = nil) {
        self.id = id
        self.time = time
        self.appBundleID = appBundleID
        self.context = context
    }
}

/// Why a session starts where it does.
public enum SessionStart: Sendable, Equatable {
    case first
    case gap(minutes: Int)
    case appSwitch(from: String, to: String, minutes: Int)
    case contextSwitch(from: String, to: String)

    /// Short machine-readable code, stored with the session.
    public var code: String {
        switch self {
        case .first: "first"
        case .gap: "gap"
        case .appSwitch: "app"
        case .contextSwitch: "context"
        }
    }

    /// Details that go with `code`, stored with the session.
    public var detail: String {
        switch self {
        case .first: ""
        case .gap(let minutes): "\(minutes)"
        case .appSwitch(let from, let to, let minutes): "\(from)\u{1F}\(to)\u{1F}\(minutes)"
        case .contextSwitch(let from, let to): "\(from)\u{1F}\(to)"
        }
    }

    /// Sentence shown to the user.
    public var explanation: String {
        switch self {
        case .first: "Erster Eintrag"
        case .gap(let minutes): "Neue Session nach \(minutes) Minuten Pause"
        case .appSwitch(let from, let to, let minutes):
            "Wechsel von \(from) zu \(to) nach \(minutes) Minuten"
        case .contextSwitch(let from, let to): "Kontextwechsel von \(from) zu \(to)"
        }
    }

    init?(code: String, detail: String) {
        let parts = detail.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(
            String.init)
        switch (code, parts.count) {
        case ("first", _): self = .first
        case ("gap", 1): self = .gap(minutes: Int(parts[0]) ?? 0)
        case ("app", 3):
            self = .appSwitch(from: parts[0], to: parts[1], minutes: Int(parts[2]) ?? 0)
        case ("context", 2): self = .contextSwitch(from: parts[0], to: parts[1])
        default: return nil
        }
    }
}

/// A contiguous run of events.
public struct SessionDraft: Sendable, Equatable {
    public let events: [SessionEvent]
    public let start: SessionStart
    public var firstEventID: Int64 { events[0].id }
    public var startedAt: Date { events[0].time }
    public var endedAt: Date { events[events.count - 1].time }
}

/// Pure, deterministic session cutting: the same events always give the same sessions.
public enum SessionSegmenter {
    public static func segment(
        _ events: [SessionEvent], configuration: SessionConfiguration = .default
    ) -> [SessionDraft] {
        let ordered = events.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        guard let first = ordered.first else { return [] }

        var drafts: [SessionDraft] = []
        var current = [first]
        var start = SessionStart.first
        var sessionContext = first.context
        var lastApp = first.appBundleID

        for index in ordered.indices.dropFirst() {
            let event = ordered[index]
            let previous = ordered[index - 1]
            let pause = event.time.timeIntervalSince(previous.time)
            let minutes = Int(pause / 60)

            var newStart: SessionStart?
            if pause > configuration.gap {
                newStart = .gap(minutes: minutes)
            } else if let from = lastApp, let to = event.appBundleID, from != to,
                pause > configuration.appSwitchGap
            {
                newStart = .appSwitch(from: from, to: to, minutes: minutes)
            } else if let from = sessionContext, let to = event.context, from != to,
                isConfirmed(context: to, at: index, in: ordered, configuration: configuration)
            {
                newStart = .contextSwitch(from: from, to: to)
            }

            if let newStart {
                drafts.append(SessionDraft(events: current, start: start))
                current = [event]
                start = newStart
                sessionContext = event.context
                lastApp = event.appBundleID
            } else {
                current.append(event)
                if sessionContext == nil { sessionContext = event.context }
                if let app = event.appBundleID { lastApp = app }
            }
        }
        drafts.append(SessionDraft(events: current, start: start))
        return drafts
    }

    /// The new context must repeat in the following copies without a session-ending pause.
    private static func isConfirmed(
        context: String, at index: Int, in events: [SessionEvent],
        configuration: SessionConfiguration
    ) -> Bool {
        let needed = configuration.contextConfirmations
        guard index + needed <= events.count else { return false }
        for offset in 0..<needed {
            let event = events[index + offset]
            guard event.context == context else { return false }
            if offset > 0,
                event.time.timeIntervalSince(events[index + offset - 1].time) > configuration.gap
            {
                return false
            }
        }
        return true
    }
}

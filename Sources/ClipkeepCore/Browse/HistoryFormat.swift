import Foundation

/// German texts of the history window. Dates use the Swiss format, like the palette.
public struct HistoryFormat: Sendable {
    private let calendar: Calendar
    private let now: Date

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    private func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_CH")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    /// "Heute", "Gestern" or "Mo 26.10.2026".
    public func dayTitle(_ day: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Heute" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(day, inSameDayAs: yesterday)
        {
            return "Gestern"
        }
        return formatter("EE dd.MM.yyyy").string(from: day)
    }

    public func time(_ date: Date) -> String { formatter("HH:mm").string(from: date) }

    public func dateTime(_ date: Date) -> String {
        formatter("dd.MM.yyyy HH:mm").string(from: date)
    }

    /// "09:15–10:02 · 12 Einträge", the title of a session row.
    public func sessionTitle(_ session: SessionSummary) -> String {
        let entries = session.eventCount == 1 ? "1 Eintrag" : "\(session.eventCount) Einträge"
        return "\(time(session.startedAt))–\(time(session.endedAt)) · \(entries)"
    }

    /// Apps and entities of a session, for the second line of its row.
    public func sessionSubtitle(_ session: SessionSummary) -> String {
        var parts = session.dominantApps.map(\.bundleID).map(Self.appName)
        parts += session.topEntities.prefix(2).map(\.value)
        return parts.joined(separator: " · ")
    }

    /// "Mehrere Tage · 3 Sessions" style summary of a topic.
    public func topicSubtitle(_ topic: TopicSummary) -> String {
        let sessions = topic.sessionCount == 1 ? "1 Session" : "\(topic.sessionCount) Sessions"
        let span =
            calendar.isDate(topic.startedAt, inSameDayAs: topic.endedAt)
            ? dayTitle(topic.endedAt)
            : "\(dayTitle(topic.startedAt)) bis \(dayTitle(topic.endedAt))"
        return "\(sessions) · \(span)"
    }

    public func entityTitle(_ entity: EntityFilter) -> String {
        "\(Self.entityKindName(entity.kind)): \(entity.value)"
    }

    public static func entityKindName(_ kind: String) -> String {
        switch kind {
        case "repo": "Repo"
        case "domain": "Domain"
        case "ticket": "Ticket"
        default: kind
        }
    }

    /// The last path component of a bundle id is the best name we have without asking the system.
    static func appName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// Lines for the score explanation: one per component that contributes, then the total.
    public func scoreLines(_ score: ScoreExplanation) -> [String] {
        let names = [
            "frecency": "Aktualität und Häufigkeit", "repetition": "Wiederholung",
            "kind": "Art", "length": "Länge", "app": "Quell-App", "star": "Stern",
            "feedback": "Rückmeldung", "pin": "Angeheftet",
        ]
        var lines = score.components.filter { $0.value != 0 }.map { component in
            "\(names[component.name] ?? component.name): \(Self.signed(component.value))"
        }
        lines.append(
            "Summe: \(Self.signed(score.total)) → Wichtigkeit \(Int((score.importance * 100).rounded())) %"
        )
        lines.append("Ablage: \(Self.tierName(score.tier))")
        return lines
    }

    static func signed(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }

    static func tierName(_ tier: Tier) -> String {
        switch tier {
        case .hot: "aktuell"
        case .warm: "älter"
        case .archive: "Archiv"
        }
    }
}

import Foundation

/// One line of the search palette: what to show for an entry.
public struct PaletteRow: Sendable, Equatable {
    public let contentID: Int64
    /// The text to copy.
    public let text: String
    public let title: String
    public let subtitle: String

    public static let maximumTitleLength = 120

    public init(hit: SearchHit, now: Date = Date(), calendar: Calendar = .current) {
        contentID = hit.contentID
        text = hit.text
        title = Self.title(of: hit.text)
        var parts: [String] = []
        if let app = hit.lastAppName { parts.append(app) }
        parts.append(Self.age(of: hit.lastCopiedAt, now: now, calendar: calendar))
        parts.append(Self.typeName(hit.kind))
        if hit.occurrenceCount > 1 { parts.append("\(hit.occurrenceCount)×") }
        subtitle = parts.joined(separator: " · ")
    }

    /// The first non-empty line, cut to fit one row.
    static func title(of text: String) -> String {
        let line =
            text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > maximumTitleLength else { return line }
        return String(line.prefix(maximumTitleLength - 1)) + "…"
    }

    static func age(of date: Date, now: Date, calendar: Calendar) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "gerade eben" }
        if seconds < 3_600 { return "vor \(Int(seconds / 60)) Min." }
        if calendar.isDate(date, inSameDayAs: now) { return "vor \(Int(seconds / 3_600)) Std." }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "gestern"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_CH")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: date)
    }

    static func typeName(_ kind: String) -> String {
        switch ContentKind(rawValue: kind) {
        case .text: "Text"
        case .url: "Link"
        case .email: "E-Mail"
        case .path: "Pfad"
        case .command: "Befehl"
        case .json: "JSON"
        case .stacktrace: "Stacktrace"
        case .code: "Code"
        case .number: "Zahl"
        case .secret: "Secret"
        case nil: "Text"
        }
    }
}

/// The search behind the palette.
public struct PaletteSearch: Sendable {
    public static let rowLimit = 20

    private let search: SearchService

    public init(database: Database) {
        search = SearchService(database: database)
    }

    /// Placeholders of parked secrets are left out: copying them would only paste their label.
    public func rows(for query: String, now: Date = Date()) throws -> [PaletteRow] {
        let hits = try search.search(
            query.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: SearchFilter(limit: Self.rowLimit * 2))
        return hits.filter { $0.kind != ContentKind.secret.rawValue }
            .prefix(Self.rowLimit).map { PaletteRow(hit: $0, now: now) }
    }
}

import Foundation

/// One line of the search palette: what to show for an entry.
public struct PaletteRow: Sendable, Equatable {
    public let contentID: Int64
    /// The text to copy.
    public let text: String
    public let title: String
    public let subtitle: String
    /// The German name of the entry's type, for tooltips and accessibility.
    public let typeName: String
    /// The SF Symbol that stands for the entry's type.
    public let symbolName: String

    public static let maximumTitleLength = 120

    public init(hit: SearchHit, now: Date = Date(), calendar: Calendar = .current) {
        contentID = hit.contentID
        typeName = Self.typeName(hit.kind)
        symbolName = HistoryRow.symbolName(for: hit.kind)
        text = hit.text
        title = Self.title(of: hit.text)
        var parts: [String] = []
        if let app = hit.lastAppName { parts.append(app) }
        parts.append(Self.age(of: hit.lastCopiedAt, now: now, calendar: calendar))
        parts.append(Self.typeName(hit.kind))
        if hit.occurrenceCount > 1 { parts.append("\(hit.occurrenceCount)×") }
        subtitle = parts.joined(separator: " · ")
    }

    /// A snippet row: `contentID` is the snippet id, the subtitle reads `age · language · count×`.
    public init(snippet: Snippet, now: Date = Date(), calendar: Calendar = .current) {
        contentID = snippet.id
        typeName = Self.languageName(snippet.language)
        let kind: ContentKind = snippet.language == .shell ? .command : .code
        symbolName = HistoryRow.symbolName(for: kind.rawValue)
        text = snippet.text
        title = Self.title(of: snippet.text)
        var parts = [Self.age(of: snippet.lastCopiedAt, now: now, calendar: calendar), typeName]
        if snippet.copyCount > 1 { parts.append("\(snippet.copyCount)×") }
        subtitle = parts.joined(separator: " · ")
    }

    static func languageName(_ language: SnippetLanguage) -> String {
        switch language {
        case .shell: "Shell"
        case .sql: "SQL"
        case .yaml: "YAML"
        }
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

/// Where the palette gets its rows from: the clipboard history or the snippet collection.
public protocol PaletteSource: Sendable {
    func rows(for query: String, now: Date) throws -> [PaletteRow]
}

/// The history search behind the palette.
public struct PaletteSearch: PaletteSource {
    public static let rowLimit = 20

    private let search: SearchService

    public init(database: Database) {
        search = SearchService(database: database)
    }

    /// Placeholders of parked secrets are left out: copying them would only paste their label.
    public func rows(for query: String, now: Date = Date()) throws -> [PaletteRow] {
        let hits = try search.search(
            query.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: SearchFilter(excludedKind: ContentKind.secret.rawValue, limit: Self.rowLimit))
        return hits.map { PaletteRow(hit: $0, now: now) }
    }
}

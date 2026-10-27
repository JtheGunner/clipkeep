import Foundation

/// What to export.
public enum ExportScope: Sendable, Equatable {
    case session(Int64)
    case day(Date)
    case topic(Int64)
}

public struct MarkdownDocument: Sendable, Equatable {
    /// kebab-case, ends in `.md`.
    public let fileName: String
    public let text: String
    public let entryCount: Int
    /// Entries left out because they hold or stand for a secret.
    public let withheldSecrets: Int
}

/// Writes sessions as readable Markdown: one section per session, one block per copy with time,
/// source and content. Secrets never leave the app: a parked secret and any text the detector
/// still flags appear as a reference line only.
public struct MarkdownExporter: Sendable {
    static let secretLine = "_Secret – gesichert, Wert nicht exportiert_"

    private let database: Database
    private let calendar: Calendar
    private let detector: SecretDetector

    public init(
        database: Database, calendar: Calendar = .current,
        detector: SecretDetector = SecretDetector()
    ) {
        self.database = database
        self.calendar = calendar
        self.detector = detector
    }

    private struct Block {
        let time: Date
        let kind: String
        let text: String
        let app: String?
        let window: String?
        let url: String?
    }

    /// Nil when the scope has no sessions with entries.
    public func export(_ scope: ExportScope) throws -> MarkdownDocument? {
        let (title, name, sessions) = try resolve(scope)
        guard !sessions.isEmpty else { return nil }
        var lines = ["# \(title)", ""]
        var count = 0
        var withheld = 0
        for session in sessions {
            let blocks = try blocks(of: session.id)
            guard !blocks.isEmpty else { continue }
            lines.append("## \(heading(of: session))")
            lines.append("")
            for block in blocks {
                count += 1
                let isSecret = block.kind == ContentKind.secret.rawValue
                // Texts and sources are scanned again here: older rows or newer detector rules
                // may catch what the capture did not.
                let source = [block.window, block.url].compactMap { $0 }.joined(separator: " ")
                let leaked =
                    !isSecret
                    && (detector.containsSecret(in: block.text)
                        || detector.containsSecret(in: source))
                if isSecret || leaked { withheld += 1 }
                lines += render(block, withhold: isSecret || leaked)
            }
        }
        guard count > 0 else { return nil }
        return MarkdownDocument(
            fileName: name + ".md", text: lines.joined(separator: "\n"), entryCount: count,
            withheldSecrets: withheld)
    }

    /// Saves into `directory` without replacing a file that is already there.
    @discardableResult
    public static func write(_ document: MarkdownDocument, to directory: URL) throws -> URL {
        guard document.fileName.hasSuffix(".md") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let base = String(document.fileName.dropLast(3))
        var number = 1
        while true {
            let name = number == 1 ? document.fileName : "\(base)-\(number).md"
            let target = directory.appendingPathComponent(name)
            // Created exclusively and private from the first moment, even in a shared folder.
            let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if descriptor < 0 {
                if errno == EEXIST {
                    number += 1
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: Data(document.text.utf8))
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            return target
        }
    }

    // MARK: - Scope

    private func resolve(_ scope: ExportScope) throws -> (String, String, [SessionSummary]) {
        let format = HistoryFormat(calendar: calendar)
        let service = SessionService(database: database)
        switch scope {
        case .session(let id):
            let sessions = try service.sessions(ids: [id])
            let start = sessions.first?.startedAt ?? Date()
            return (
                "Session \(format.dateTime(start))",
                "clipkeep-session-\(stamp(start, "yyyy-MM-dd-HHmm"))", sessions
            )
        case .day(let date):
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            let ids: [Int64] = try database.read { connection in
                try connection.query(
                    "SELECT id FROM sessions WHERE started_at >= ? AND started_at < ?",
                    [SQLValue(start), SQLValue(end)]
                ) { $0.int(0) }
            }
            return (
                "Zwischenablage \(format.dayTitle(start, relativeTo: false))",
                "clipkeep-\(stamp(start, "yyyy-MM-dd"))", try service.sessions(ids: ids)
            )
        case .topic(let id):
            let label: String? = try database.read { connection in
                try connection.query("SELECT label FROM topics WHERE id = ?", [.int(id)]) {
                    $0.text(0)
                }.first
            }
            guard let label else { return ("", "", []) }
            let ids = try TopicService(database: database).sessionIDs(inTopic: id)
            return (
                "Thema: \(Self.oneLine(label))", "clipkeep-thema-\(Self.slug(label))",
                try service.sessions(ids: ids)
            )
        }
    }

    private func stamp(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Lower-case ASCII words joined by hyphens; "thema" if nothing is left.
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        var result = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result += "-"
            }
        }
        let trimmed = String(
            result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        )
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "thema" : trimmed
    }

    // MARK: - Content

    private func heading(of session: SessionSummary) -> String {
        let format = HistoryFormat(calendar: calendar)
        var heading = "\(format.dateTime(session.startedAt)) – \(format.time(session.endedAt))"
        let sources = format.sessionSubtitle(session)
        if !sources.isEmpty { heading += " · \(Self.oneLine(sources))" }
        return heading
    }

    private func blocks(of sessionID: Int64) throws -> [Block] {
        try database.read { connection in
            try connection.query(
                """
                SELECT e.copied_at, c.kind, c.text, e.app_name, e.window_title, e.url
                FROM copy_events e JOIN contents c ON c.id = e.content_id
                WHERE e.session_id = ? AND c.deleted_at IS NULL ORDER BY e.copied_at, e.id
                """,
                [.int(sessionID)]
            ) {
                Block(
                    time: Date(timeIntervalSince1970: $0.double(0)), kind: $0.text(1),
                    text: $0.text(2), app: $0.optionalText(3), window: $0.optionalText(4),
                    url: $0.optionalText(5))
            }
        }
    }

    private func render(_ block: Block, withhold: Bool) -> [String] {
        let format = HistoryFormat(calendar: calendar)
        var title = "### \(format.time(block.time))"
        if let app = block.app { title += " · \(Self.oneLine(app))" }
        title += " · \(PaletteRow.typeName(block.kind))"
        var lines = [title, ""]
        // A withheld entry shows no source either: its window title may hold the secret too.
        let source = [block.window, block.url].compactMap { $0 }.map(Self.oneLine)
            .filter { !$0.isEmpty }
        if !withhold, !source.isEmpty { lines += ["> " + source.joined(separator: " · "), ""] }
        if withhold {
            lines += [Self.secretLine, ""]
        } else {
            let fence = String(
                repeating: "`", count: max(3, Self.longestBacktickRun(block.text) + 1))
            let language = block.kind == ContentKind.json.rawValue ? "json" : "text"
            lines += ["\(fence)\(language)", block.text, fence, ""]
        }
        return lines
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}

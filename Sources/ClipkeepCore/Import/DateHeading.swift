import Foundation

/// A line of an imported text file that consists of nothing but a date, such as `2024-03-05`,
/// `## 5.3.2024`, `Dienstag, 5. März 2024` or `March 5, 2024 14:30`. The entries below it are
/// dated with it.
///
/// Dates with slashes (`03/05/2024`) are not recognised: day and month cannot be told apart.
struct DateHeading: Sendable, Equatable {
    static let defaultHour = 9
    private static let years = 1970...2100

    let year: Int
    let month: Int
    let day: Int
    let hour: Int?
    let minute: Int?

    /// The heading's moment in local time; without a time of day, `defaultHour` o'clock.
    var date: Date? {
        var components = DateComponents(
            year: year, month: month, day: day, hour: hour ?? Self.defaultHour, minute: minute ?? 0)
        components.calendar = Calendar.current
        guard let date = components.date else { return nil }
        // A date like February 30th would roll over silently; refuse it instead.
        let check = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day ? date : nil
    }

    /// The heading a line stands for, or nil when the line is anything else.
    static func parse(_ line: Substring) -> DateHeading? {
        let text = line.trimmingCharacters(in: decoration)
        guard !text.isEmpty, text.count <= 60 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: text, range: range) else { continue }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound
                    ? nil : Range(range, in: text).map { String(text[$0]) }
            }
            guard let parts = pattern.read(group) else { continue }
            let heading = DateHeading(
                year: parts.year, month: parts.month, day: parts.day,
                hour: group(pattern.hourGroup).flatMap(Int.init),
                minute: group(pattern.hourGroup + 1).flatMap(Int.init))
            guard years.contains(heading.year), (0..<24).contains(heading.hour ?? 0),
                (0..<60).contains(heading.minute ?? 0), heading.date != nil
            else { return nil }
            return heading
        }
        return nil
    }

    /// Markdown markers and punctuation around a heading.
    private static let decoration = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: "#*_>[]():"))

    private struct Pattern: Sendable {
        let regex: NSRegularExpression
        /// Group number of the hour; the minute follows.
        let hourGroup: Int
        let read: @Sendable ((Int) -> String?) -> (year: Int, month: Int, day: Int)?
    }

    private static let weekday =
        "(?:(?:mo|di|mi|do|fr|sa|so|mon|tue|wed|thu|fri|sat|sun)[a-zäö]*\\.?,?\\s+)?"
    private static let time = "(?:[,\\sT]+(\\d{1,2}):(\\d{2})(?::\\d{2})?(?:\\s*Uhr)?)?"

    private static func pattern(
        _ body: String, hourGroup: Int,
        read: @escaping @Sendable ((Int) -> String?) -> (year: Int, month: Int, day: Int)?
    ) -> Pattern {
        // The expressions are constants; one that does not compile would fail every test.
        let regex = try! NSRegularExpression(
            pattern: "^" + weekday + body + time + "$", options: [.caseInsensitive])
        return Pattern(regex: regex, hourGroup: hourGroup, read: read)
    }

    private static let patterns: [Pattern] = [
        // 2024-03-05
        pattern("(\\d{4})-(\\d{1,2})-(\\d{1,2})", hourGroup: 4) { group in
            numbers(group(1), group(2), group(3)).map { (year: $0[0], month: $0[1], day: $0[2]) }
        },
        // 5.3.2024
        pattern("(\\d{1,2})\\.\\s?(\\d{1,2})\\.\\s?(\\d{4})", hourGroup: 4) { group in
            numbers(group(3), group(2), group(1)).map { (year: $0[0], month: $0[1], day: $0[2]) }
        },
        // 5. März 2024, 5 March 2024
        pattern("(\\d{1,2})\\.?\\s+([a-zäÄ]{3,9})\\.?,?\\s+(\\d{4})", hourGroup: 4) { group in
            guard let month = monthNumber(group(2)),
                let values = numbers(group(3), group(1))
            else { return nil }
            return (year: values[0], month: month, day: values[1])
        },
        // March 5, 2024, March 5th 2024
        pattern(
            "([a-zäÄ]{3,9})\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})", hourGroup: 4
        ) { group in
            guard let month = monthNumber(group(1)),
                let values = numbers(group(3), group(2))
            else { return nil }
            return (year: values[0], month: month, day: values[1])
        },
    ]

    private static func numbers(_ texts: String?...) -> [Int]? {
        let values = texts.compactMap { $0.flatMap(Int.init) }
        return values.count == texts.count ? values : nil
    }

    private static let months: [String: Int] = [
        "januar": 1, "january": 1, "jan": 1, "februar": 2, "february": 2, "feb": 2,
        "märz": 3, "maerz": 3, "march": 3, "mär": 3, "mar": 3, "april": 4, "apr": 4,
        "mai": 5, "may": 5, "juni": 6, "june": 6, "jun": 6, "juli": 7, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9, "oktober": 10,
        "october": 10, "okt": 10, "oct": 10, "november": 11, "nov": 11, "dezember": 12,
        "december": 12, "dez": 12, "dec": 12,
    ]

    private static func monthNumber(_ name: String?) -> Int? {
        name.flatMap { months[$0.lowercased()] }
    }
}

import Foundation

/// How a collected text document is cut into entries.
public enum SplitMode: String, Sendable, CaseIterable, Equatable {
    /// Separator lines if the document has any, else blank lines, else one entry per line.
    case automatic
    /// A line of three or more `-`, `=`, `*`, `_`, `~` or `#` ends an entry.
    case separatorLines
    /// One or more blank lines end an entry.
    case blankLines
    case everyLine
}

public enum TextSplitter {
    /// The entries in file order, trimmed, without empty ones.
    public static func split(_ text: String, mode: SplitMode = .automatic) -> [String] {
        let lines = Self.lines(of: text)
        switch resolve(mode, lines: lines) {
        case .everyLine: return clean(lines.map(String.init))
        case .separatorLines: return group(lines) { isSeparator($0) }
        case .blankLines, .automatic: return group(lines) { $0.allSatisfy(\.isWhitespace) }
        }
    }

    /// The mode `automatic` stands for in this document.
    public static func resolve(_ mode: SplitMode, text: String) -> SplitMode {
        resolve(mode, lines: lines(of: text))
    }

    /// Surrounding blank space is dropped first, so a final line break is not a blank line.
    private static func lines(of text: String) -> [Substring] {
        CaptureStages.normalize(text).split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func resolve(_ mode: SplitMode, lines: [Substring]) -> SplitMode {
        guard mode == .automatic else { return mode }
        if lines.contains(where: isSeparator) { return .separatorLines }
        if lines.contains(where: { $0.allSatisfy(\.isWhitespace) }) { return .blankLines }
        return .everyLine
    }

    static func isSeparator(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first, "-=*_~#".contains(first) else {
            return false
        }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func group(_ lines: [Substring], isBreak: (Substring) -> Bool) -> [String] {
        var entries: [String] = []
        var current: [Substring] = []
        for line in lines {
            if isBreak(line) {
                entries.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(line)
            }
        }
        entries.append(current.joined(separator: "\n"))
        return clean(entries)
    }

    private static func clean(_ entries: [String]) -> [String] {
        entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

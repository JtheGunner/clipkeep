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
        let armored = armoredLines(lines)
        let entries: [String]
        switch resolve(mode, lines: lines) {
        case .everyLine: entries = perLine(lines, armored: armored)
        case .separatorLines: entries = group(lines, armored: armored) { isSeparator($0) }
        case .blankLines, .automatic:
            entries = group(lines, armored: armored) { $0.allSatisfy(\.isWhitespace) }
        }
        return joinLabels(entries)
    }

    /// Lines inside `-----BEGIN …-----` / `-----END …-----` blocks (keys, certificates). They are
    /// never cut apart, whatever the mode: a key split into pieces would leak the pieces the
    /// secret detector cannot recognise on their own. An unclosed block is not protected.
    static func armoredLines(_ lines: [Substring]) -> [Bool] {
        var armored = [Bool](repeating: false, count: lines.count)
        var open: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFrame = trimmed.hasPrefix("-----") && trimmed.hasSuffix("-----")
            if let start = open {
                if isFrame, trimmed.contains("END") {
                    for inside in start...index { armored[inside] = true }
                    open = nil
                } else if index - start > maximumArmoredLines {
                    open = nil
                }
            } else if isFrame, trimmed.contains("BEGIN") {
                open = index
            }
        }
        return armored
    }

    static let maximumArmoredLines = 400

    private static let labelPattern = try? NSRegularExpression(
        pattern:
            "(pass|pwd|kennwort|secret|token|key|schl[uü]ssel|credential|zugang)[^\\n]{0,30}[:=]\\s*$",
        options: [.caseInsensitive])

    /// A label that ends in a colon ("Passwort:") belongs to the entry after it, otherwise the
    /// value would be stored apart from the word that makes it recognisable as a secret.
    static func joinLabels(_ entries: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < entries.count {
            var entry = entries[index]
            while index + 1 < entries.count, endsWithLabel(entry) {
                index += 1
                entry += "\n" + entries[index]
            }
            result.append(entry)
            index += 1
        }
        return result
    }

    private static func endsWithLabel(_ entry: String) -> Bool {
        let last = entry.split(separator: "\n").last.map(String.init) ?? entry
        let range = NSRange(last.startIndex..., in: last)
        return labelPattern?.firstMatch(in: last, range: range) != nil
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

    /// Cuts at lines for which `isBreak` holds, except inside an armored block.
    private static func group(
        _ lines: [Substring], armored: [Bool], isBreak: (Substring) -> Bool
    ) -> [String] {
        var entries: [String] = []
        var current: [Substring] = []
        for (index, line) in lines.enumerated() {
            if !armored[index], isBreak(line) {
                entries.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(line)
            }
        }
        entries.append(current.joined(separator: "\n"))
        return clean(entries)
    }

    /// One entry per line, except that an armored block stays together.
    private static func perLine(_ lines: [Substring], armored: [Bool]) -> [String] {
        var entries: [String] = []
        var block: [Substring] = []
        for (index, line) in lines.enumerated() {
            if armored[index] {
                block.append(line)
                continue
            }
            if !block.isEmpty {
                entries.append(block.joined(separator: "\n"))
                block = []
            }
            entries.append(String(line))
        }
        if !block.isEmpty { entries.append(block.joined(separator: "\n")) }
        return clean(entries)
    }

    private static func clean(_ entries: [String]) -> [String] {
        entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

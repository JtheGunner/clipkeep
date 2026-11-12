import Foundation

/// The subject of a snippet, read from its text instead of stored: the program of a shell
/// command, the first table of a SQL statement, the kind or first key of a YAML document. It is
/// lower case so the same subject groups together however it was typed.
public enum SnippetTopic {
    /// Words that run another program and are not the subject themselves.
    private static let wrappers: Set<String> = [
        "sudo", "env", "time", "nohup", "command", "exec", "nice", "xargs",
    ]
    private static let programName = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._+-]+$"#)
    private static let assignment = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_]*=.*$"#)
    private static let table = try! NSRegularExpression(
        pattern:
            #"\b(?:from|into|update|table|join)\s+(?:if\s+(?:not\s+)?exists\s+)?([`"\[]?[A-Za-z_][\w.]*[`"\]]?)"#,
        options: [.caseInsensitive])
    private static let topLevelKey = try! NSRegularExpression(
        pattern: #"^([A-Za-z_][\w.-]*):(?:\s+(.*))?$"#)

    public static func of(_ text: String, language: SnippetLanguage) -> String? {
        switch language {
        case .shell: shellTopic(text)
        case .sql: sqlTopic(text)
        case .yaml: yamlTopic(text)
        }
    }

    public static func of(_ snippet: Snippet) -> String? {
        of(snippet.text, language: snippet.language)
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func shellTopic(_ text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("$ ") { line = String(line.dropFirst(2)) }
            for word in line.split(whereSeparator: \.isWhitespace).map(String.init) {
                if matches(assignment, word) || wrappers.contains(word) || word.hasPrefix("-") {
                    continue
                }
                let name = word.split(separator: "/").last.map(String.init) ?? word
                return matches(programName, name) ? name.lowercased() : nil
            }
            return nil
        }
        return nil
    }

    private static func sqlTopic(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for match in table.matches(in: text, range: range) {
            guard let found = Range(match.range(at: 1), in: text) else { continue }
            let name = text[found].filter { !"`\"[]".contains($0) }
            if !name.isEmpty { return name.lowercased() }
        }
        return nil
    }

    private static func yamlTopic(_ text: String) -> String? {
        var firstKey: String?
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            // Only keys at the left edge count; anything indented is nested.
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-" else {
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = topLevelKey.firstMatch(in: line, range: range),
                let keyRange = Range(match.range(at: 1), in: line)
            else { continue }
            let key = String(line[keyRange])
            if firstKey == nil { firstKey = key }
            if key == "kind", match.range(at: 2).location != NSNotFound,
                let valueRange = Range(match.range(at: 2), in: line)
            {
                let kind = line[valueRange].trimmingCharacters(in: .whitespaces)
                if !kind.isEmpty { return kind.lowercased() }
            }
        }
        return firstKey?.lowercased()
    }
}

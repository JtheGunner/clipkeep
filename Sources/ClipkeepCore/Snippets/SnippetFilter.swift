import Foundation

/// Decides whether a copied text is a reusable shell, SQL or YAML snippet. Strict, pure and
/// deterministic: when in doubt it answers `nil`. Runs on already anonymised text.
public enum SnippetFilter {
    /// Starting values, tuned by the evaluation (see docs/plans/CLIPK-54-design.md).
    enum Threshold {
        /// Larger texts are logs or files, not snippets, and are rejected without inspection.
        static let maximumBytes = 32 * 1024
        /// Only the start of a text is inspected, which bounds every rule below.
        static let maximumInspectedLines = 60
        /// Single-line texts shorter than this are too small to be worth keeping.
        static let minimumSingleLineLength = 8
        /// An unambiguous command needs this many arguments when it has no flag or operator.
        static let minimumShellArguments = 2
        /// Plain command lines (no flags or operators) count as a script from this many lines.
        static let minimumPlainShellLines = 2
        /// YAML needs at least this many structural lines.
        static let minimumYAMLLines = 3
        /// Share of inspected lines that must have YAML shape.
        static let minimumYAMLLineShare = 0.9
        /// A line ending like a sentence with at least this many words reads as prose.
        static let minimumProseWords = 6
        /// Texts where at least this share of lines reads as prose are rejected.
        static let maximumProseLineShare = 0.5
    }

    private static let rejectedKinds: Set<ContentKind> = [
        .url, .email, .path, .number, .json, .stacktrace, .secret,
    ]

    public static func evaluate(_ text: String) -> SnippetLanguage? {
        guard text.utf8.count <= Threshold.maximumBytes else { return nil }
        let lines = normalizedLines(of: text)
        guard !lines.isEmpty else { return nil }
        let normalized = lines.joined(separator: "\n")
        if lines.count == 1, normalized.count < Threshold.minimumSingleLineLength { return nil }
        guard !rejectedKinds.contains(ContentClassifier.classify(normalized)) else { return nil }
        guard !isMostlyProse(lines) else { return nil }

        if SQLRule.matches(lines) { return .sql }
        if ShellRule.matches(lines) { return .shell }
        if YAMLRule.matches(lines) { return .yaml }
        return nil
    }

    /// Unifies line breaks, drops trailing whitespace and surrounding blank lines, and keeps only
    /// the inspected start of the text, so CRLF and trailing spaces never change the verdict.
    private static func normalizedLines(of text: String) -> [String] {
        var lines: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = String(rawLine.reversed().drop(while: \.isWhitespace).reversed())
            if lines.isEmpty, trimmed.isEmpty { continue }
            lines.append(trimmed)
            if lines.count == Threshold.maximumInspectedLines { break }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func isMostlyProse(_ lines: [String]) -> Bool {
        let content = lines.filter { !$0.isEmpty }
        let prose = content.filter { line in
            guard let last = line.last, ".?!".contains(last) else { return false }
            return line.split(whereSeparator: \.isWhitespace).count >= Threshold.minimumProseWords
        }
        return !prose.isEmpty
            && Double(prose.count) >= Double(content.count) * Threshold.maximumProseLineShare
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants covered by tests, so a failure is a programmer error.
        try! NSRegularExpression(pattern: pattern)
    }
}

/// A statement that starts with a recognised verb and carries its structure.
private enum SQLRule {
    private static let statements = SnippetFilter.regex(
        #"(?is)^(?:SELECT\s.{1,4000}?\sFROM\s+\S|INSERT\s+INTO\s+\S.{0,4000}?\b(?:VALUES|SELECT)\b|UPDATE\s+\S+\s+SET\s+\S+\s*=|DELETE\s+FROM\s+\S|CREATE\s+(?:OR\s+REPLACE\s+)?(?:TEMP(?:ORARY)?\s+)?(?:TABLE|VIEW|(?:UNIQUE\s+)?INDEX)\s+\S|ALTER\s+TABLE\s+\S+\s+\w|WITH\s+(?:RECURSIVE\s+)?\w+\s*(?:\([^)]{0,500}\))?\s+AS\s*\()"#
    )
    /// Upper-case verbs, a terminating semicolon or SQL punctuation set a query apart from a
    /// sentence such as "Select the best option from the list".
    private static let structure = SnippetFilter.regex(
        #"^(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|WITH)\b|;$|[*=(]"#)

    static func matches(_ lines: [String]) -> Bool {
        let statement = lines.filter { !$0.hasPrefix("--") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = statement.last, !".?!".contains(last) else { return false }
        return SnippetFilter.matches(statements, statement)
            && SnippetFilter.matches(structure, statement)
    }
}

/// A command with real arguments, or several plain command lines.
private enum ShellRule {
    /// Command names that are also everyday words; they need a flag or an operator to count.
    private static let ambiguousCommands: Set<String> = [
        "go", "make", "find", "cat", "kill", "cd", "ps", "echo", "open", "head", "tail", "less",
        "touch", "export", "tar", "gem", "bundle", "ls", "mv", "cp", "rm", "node", "java", "sort",
        "uniq", "wc", "cut", "tr", "xargs", "diff", "ln", "du", "df", "jq", "tee", "which",
        "date", "man", "ping", "dig", "lsof", "top", "stat", "file", "source", "env", "sleep",
        "time", "test", "type", "watch", "say", "code",
    ]
    private static let unambiguousCommands: Set<String> = [
        "git", "docker", "docker-compose", "podman", "npm", "npx", "yarn", "pnpm", "composer",
        "php", "artisan", "kubectl", "helm", "k9s", "brew", "curl", "wget", "ssh", "scp", "sudo",
        "swift", "python", "python3", "pip", "pip3", "cargo", "rustup", "terraform", "tmux",
        "mkdir", "chmod", "chown", "sed", "awk", "gh", "rake", "mvn", "gradle", "ansible",
        "ansible-playbook", "systemctl", "journalctl", "unzip", "zip", "apt", "apt-get", "yum",
        "dnf", "pacman", "rsync", "defaults", "launchctl", "diskutil", "xcodebuild", "xcrun",
        "psql", "mysql", "redis-cli", "sqlite3", "uv", "pipx", "deno", "bun", "dotnet", "ruby",
        "grep", "rg", "fd", "openssl", "gpg", "aws", "gcloud", "az", "nc", "netstat", "dd",
        "ffmpeg", "pg_dump", "mysqldump", "pkill", "killall", "unset", "bash", "sh", "zsh",
    ]
    private static let promptPrefix = SnippetFilter.regex(#"^[$%]\s+"#)
    private static let envAssignments = SnippetFilter.regex(
        #"^(?:[A-Za-z_][A-Za-z0-9_]{0,63}=\S{0,500}\s+)+"#)
    private static let operators = SnippetFilter.regex(
        #"\s\|\s?|\|\||&&|;\s|;$|\s[<>]|\d?>{1,2}\s?\S|\$\(|\$\{|\$[A-Za-z_]|`"#)
    private static let flag = SnippetFilter.regex(#"^-{1,2}[A-Za-z0-9]"#)

    private enum LineKind {
        case rich
        case plain
        case other
    }

    static func matches(_ lines: [String]) -> Bool {
        let content = joinedContinuations(lines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && (!trimmed.hasPrefix("#") || trimmed.hasPrefix("#!"))
        }
        guard !content.isEmpty else { return false }
        let kinds = content.map(kind(of:))
        guard !kinds.contains(.other) else { return false }
        return kinds.contains(.rich)
            || kinds.count >= SnippetFilter.Threshold.minimumPlainShellLines
    }

    private static func joinedContinuations(_ lines: [String]) -> [String] {
        var joined: [String] = []
        var pending = ""
        for line in lines {
            if line.hasSuffix("\\") {
                pending += line.dropLast() + " "
                continue
            }
            joined.append(pending + line)
            pending = ""
        }
        if !pending.isEmpty { joined.append(pending) }
        return joined
    }

    private static func kind(of rawLine: String) -> LineKind {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#!") { return .rich }
        line = stripping(promptPrefix, from: line)
        line = stripping(envAssignments, from: line)
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = words.first else { return .other }
        let isExecutablePath = command.hasPrefix("./") || command.hasPrefix("~/")
        let isAmbiguous = ambiguousCommands.contains(command)
        guard isExecutablePath || isAmbiguous || unambiguousCommands.contains(command) else {
            return .other
        }
        let arguments = words.dropFirst()
        let hasFlag = arguments.contains { SnippetFilter.matches(flag, $0) }
        let hasOperator = SnippetFilter.matches(operators, line)
        if hasFlag || hasOperator { return .rich }
        // "git is a nice tool." is prose, not a command.
        if let last = line.last, ".?!".contains(last) { return .other }
        if isAmbiguous { return .other }
        if arguments.count >= SnippetFilter.Threshold.minimumShellArguments { return .rich }
        return .plain
    }

    private static func stripping(_ regex: NSRegularExpression, from text: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

/// Several `key: value` lines with consistent indentation and real nesting.
private enum YAMLRule {
    private static let keyLine = SnippetFilter.regex(
        #"^(?:-\s+)?(?:"[^"]{1,100}"|'[^']{1,100}'|[A-Za-z0-9_][A-Za-z0-9_.\-/]{0,100})\s*:(?:\s+(.*))?$"#
    )
    private static let listItem = SnippetFilter.regex(#"^-(?:\s+\S.*)?$"#)
    /// `- name = value` is key/value notation from forms, notifications or INI files. YAML would
    /// read it as one plain string, so it is no evidence of YAML structure. (`- NAME=value`
    /// without spaces is a common YAML list of environment variables and still counts.)
    private static let spacedAssignmentItem = SnippetFilter.regex(
        #"^-\s+[A-Za-z0-9_.\-]{1,100}\s+=(?:\s|$)"#)

    private struct Line {
        let indent: Int
        let isKey: Bool
        /// `key:` with nothing after it, which opens a nested block.
        let opensBlock: Bool
        /// `key: |` or `key: >`, whose deeper lines are free text.
        let opensScalar: Bool
        let isListItem: Bool
    }

    static func matches(_ lines: [String]) -> Bool {
        let content = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed != "---"
        }
        guard !content.contains(where: { $0.contains("\t") }) else { return false }
        let parsed = structuralLines(content)
        guard parsed.count >= SnippetFilter.Threshold.minimumYAMLLines else { return false }
        let shaped = parsed.filter { $0.isKey || $0.isListItem }
        let share = Double(shaped.count) / Double(parsed.count)
        guard share >= SnippetFilter.Threshold.minimumYAMLLineShare else { return false }
        return hasConsistentIndentation(parsed) && hasNesting(parsed)
    }

    /// Parses the lines and skips the free-text bodies of block scalars.
    private static func structuralLines(_ content: [String]) -> [Line] {
        var result: [Line] = []
        var scalarIndent: Int?
        for raw in content {
            let indent = raw.prefix(while: { $0 == " " }).count
            if let open = scalarIndent {
                if indent > open { continue }
                scalarIndent = nil
            }
            let line = parse(raw, indent: indent)
            if line.opensScalar { scalarIndent = indent }
            result.append(line)
        }
        return result
    }

    private static func parse(_ raw: String, indent: Int) -> Line {
        let body = String(raw.dropFirst(indent))
        let range = NSRange(body.startIndex..., in: body)
        let match = keyLine.firstMatch(in: body, range: range)
        let value = match.flatMap { Range($0.range(at: 1), in: body) }.map { body[$0] } ?? ""
        let isKey = match != nil
        return Line(
            indent: indent, isKey: isKey,
            opensBlock: isKey && value.isEmpty,
            opensScalar: isKey && (value.hasPrefix("|") || value.hasPrefix(">")),
            isListItem: SnippetFilter.matches(listItem, body)
                && !SnippetFilter.matches(spacedAssignmentItem, body))
    }

    /// Every indent is a multiple of the smallest one, and a line only goes deeper below a line
    /// that can hold children.
    private static func hasConsistentIndentation(_ lines: [Line]) -> Bool {
        let unit = lines.map(\.indent).filter { $0 > 0 }.min() ?? 1
        guard lines.allSatisfy({ $0.indent % unit == 0 }) else { return false }
        for (previous, line) in zip(lines, lines.dropFirst()) where line.indent > previous.indent {
            let canHoldChildren =
                previous.opensBlock || previous.opensScalar
                || (previous.isListItem && previous.isKey)
            guard canHoldChildren else { return false }
        }
        return true
    }

    /// A flat list of `key: value` lines reads like headers or notes, and a heading over a plain
    /// bullet list reads like a form or a note. YAML worth keeping nests a mapping: a key line
    /// directly below a deeper-holding key line.
    private static func hasNesting(_ lines: [Line]) -> Bool {
        zip(lines, lines.dropFirst()).contains { previous, line in
            line.indent > previous.indent && previous.isKey && line.isKey
        }
    }
}

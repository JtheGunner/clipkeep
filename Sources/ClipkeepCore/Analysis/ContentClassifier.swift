import Foundation

/// Decides what a copied text is, using fixed rules in a fixed order. The first rule that
/// matches wins, so cheap and unambiguous checks come first.
public enum ContentClassifier {
    /// Command names that are also everyday words ("go to the store", "make sure"). They only
    /// count as a command when the line carries a shell signal such as a flag, a path or a pipe.
    private static let ambiguousCommands: Set<String> = [
        "go", "make", "find", "cat", "kill", "cd", "ps", "echo", "open", "head", "tail", "less",
        "touch", "export", "set", "tar", "gem", "bundle", "ls", "mv", "cp", "rm", "node", "java",
        "sort",
        "uniq", "wc", "cut", "tr", "xargs", "diff", "ln", "du", "df", "jq", "tee", "which", "date",
        "history", "man", "ping", "dig", "lsof", "top", "stat", "file", "source", "alias", "env",
        "true", "exit", "clear", "whoami", "pwd", "sleep", "time", "test", "read", "type", "yes",
    ]
    private static let commands: Set<String> = ambiguousCommands.union([
        "git", "docker", "npm", "npx", "yarn", "pnpm", "composer", "php", "artisan", "kubectl",
        "brew",
        "curl", "wget", "ssh", "scp", "sudo", "swift", "python", "python3", "pip", "pip3", "cargo",
        "terraform", "helm", "tmux", "mkdir", "chmod", "chown", "sed", "awk", "gh", "rake", "mvn",
        "gradle", "ansible", "systemctl", "journalctl", "unzip", "apt", "apt-get", "yum", "dnf",
        "pacman", "rsync", "nano", "vim", "defaults", "launchctl", "diskutil", "xcodebuild", "psql",
        "mysql", "redis-cli", "uv", "pipx", "deno", "bun", "dotnet", "ruby", "grep",
    ])

    private static let number = regex(
        #"^[+\-]?(?:\d{1,3}(?:[,' ]\d{3})+|\d+)(?:[.,]\d+)?$"#)
    private static let email = regex(#"^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$"#)
    private static let url = regex(#"^(?:https?://|ftp://|mailto:|www\.)\S+$"#)
    private static let windowsPath = regex(#"^[A-Za-z]:\\"#)
    private static let envAssignments = regex(#"^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+"#)
    private static let promptPrefix = regex(
        #"^(?:[^\s@]{1,64}@[^\s:]{1,255}:[^\s$#%]{0,1024}[$#%]|[$%])\s+"#)
    private static let shellSignal = regex(#"(?:\s-{1,2}[A-Za-z]|[|&;<>$~=]|\./|\s/|^\S+$)"#)
    private static let stackFrames = [
        // Java and JavaScript frames name a dotted or slashed symbol and a location; the segment
        // separator is not part of the segment class, so the match cannot backtrack.
        regex(
            #"^\s*at\s+(?:async\s+)?[\w$<>\[\]\-]+(?:[./][\w$<>\[\]\-]+)+\s*\([^\n)]{0,300}\)"#),
        regex(#"^\s*at\s+\S+:\d+(?::\d+)?$"#),  // Node frames without parentheses
        regex(#"^\s*File ".+", line \d+"#),  // Python
        regex(#"^\s*#\d+\s+0x[0-9a-fA-F]+"#),  // native backtraces
        regex(#"^\s*\d+\s+\S+\s+0x[0-9a-fA-F]+\s"#),  // Apple crash logs
    ]
    private static let stackHeaders = regex(
        #"(?m)^(?:Traceback \(most recent call last\):|Exception in thread|Fatal error:|Uncaught \w*(?:Error|Exception)|PHP (?:Fatal|Warning))"#
    )
    private static let codeSignals = regex(
        #"\b(?:func|function|def|fn)\s+\w*\s*\(|\b(?:class|struct|enum|interface|impl|namespace)\s+\w+\s*(?:[{:(<]|extends|implements|$)|\b(?:const|let|var)\s+\w+\s*[=:]|^\s*import\s+[\w.{}*,]{1,200}(?:\s+from\s|;|$)|\breturn\b[^\n]*;|=>|::|<\?php|</?[a-z][a-z0-9]*[ >]"#
    )

    /// Pastes beyond this size are plain text: classifying them costs time inside the capture path
    /// and no rule here is meant for megabyte-sized content.
    static let maximumClassifiedBytes = 1_048_576
    /// Line-based rules look at the start of the text only.
    static let sampleCharacters = 32 * 1024
    /// Real stack frames are short; longer lines are skipped by the frame rules.
    static let maximumFrameLineLength = 500
    /// Line-based rules inspect at most this many lines; the start of a text shows what it is.
    static let maximumInspectedLines = 60
    /// Each inspected line is cut to this length, which bounds every per-line regex.
    static let maximumInspectedLineLength = 500

    public static func classify(_ text: String) -> ContentKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumClassifiedBytes else { return .text }
        let isSingleLine = !trimmed.contains(where: \.isNewline)

        if isSingleLine {
            if matches(number, trimmed) { return .number }
            if matches(url, trimmed) { return .url }
            if matches(email, trimmed) { return .email }
            if isPath(trimmed) { return .path }
        }
        if isJSON(trimmed) { return .json }
        let sample = String(trimmed.prefix(sampleCharacters))
        if isStackTrace(sample) { return .stacktrace }
        if isCommand(sample) { return .command }
        if isCode(sample, isSingleLine: isSingleLine) { return .code }
        return .text
    }

    private static func isPath(_ text: String) -> Bool {
        guard text.count <= 1024 else { return false }
        let prefixes = ["/", "~/", "./", "../"]
        let hasPrefix = prefixes.contains { text.hasPrefix($0) } || matches(windowsPath, text)
        guard hasPrefix else { return false }
        // A lone "/" or a sentence that merely starts with a slash is not a path.
        return text.count > 1 && !text.hasSuffix(".") && !text.contains(": ")
    }

    private static func isJSON(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last,
            (first == "{" && last == "}") || (first == "[" && last == "]")
        else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    private static func isStackTrace(_ text: String) -> Bool {
        let lines = inspectedLines(of: text)
        let frames = lines.filter { line in
            line.count <= maximumFrameLineLength && stackFrames.contains { matches($0, line) }
        }
        if frames.count >= 2 { return true }
        return matches(stackHeaders, text) && lines.count >= 2
    }

    private static func isCommand(_ text: String) -> Bool {
        if text.hasPrefix("#!") { return true }
        var line = String(text.prefix(while: { !$0.isNewline })).trimmingCharacters(
            in: .whitespaces)
        line = replacing(promptPrefix, in: line)
        line = replacing(envAssignments, in: line)

        let word = String(line.prefix(while: { !$0.isWhitespace }))
        guard commands.contains(word) else { return false }
        if ambiguousCommands.contains(word) { return matches(shellSignal, line) }
        // "git is a tool." is prose; a command has arguments or stands alone without a period.
        return !line.hasSuffix(".") || line.contains(" -")
    }

    private static func isCode(_ text: String, isSingleLine: Bool) -> Bool {
        let lines = inspectedLines(of: text)
        let signalLines = lines.filter { matches(codeSignals, $0) }.count
        let punctuationLines = lines.filter { line in
            guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
            return ";{}".contains(last) || line.contains(" = ")
        }.count
        if isSingleLine {
            return signalLines > 0 && punctuationLines > 0 && text.contains("(")
                && text.contains(")")
        }
        return signalLines + punctuationLines >= 3 && signalLines >= 1 && lines.count >= 2
    }

    private static func inspectedLines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).prefix(maximumInspectedLines).map {
            String($0.prefix(maximumInspectedLineLength))
        }
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants covered by tests, so a failure is a programmer error.
        try! NSRegularExpression(pattern: pattern)
    }
}

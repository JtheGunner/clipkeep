import Foundation

/// Decides what a copied text is, using fixed rules in a fixed order. The first rule that
/// matches wins, so cheap and unambiguous checks come first.
public enum ContentClassifier {
    private static let commands: Set<String> = [
        "git", "docker", "npm", "npx", "yarn", "pnpm", "composer", "php", "artisan", "kubectl",
        "brew",
        "cd", "ls", "cat", "grep", "curl", "wget", "ssh", "scp", "sudo", "make", "swift", "python",
        "python3", "pip", "pip3", "go", "cargo", "terraform", "helm", "tmux", "rm", "mv", "cp",
        "mkdir", "chmod", "chown", "find", "sed", "awk", "gh", "node", "bundle", "rake", "mvn",
        "gradle", "ansible", "systemctl", "journalctl", "tar", "unzip", "ps", "kill", "echo",
        "export",
    ]

    private static let number = regex(#"^[+\-]?\d[\d.,' _]*$"#)
    private static let email = regex(#"^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$"#)
    private static let url = regex(#"^(?:https?://|ftp://|mailto:|www\.)\S+$"#)
    private static let windowsPath = regex(#"^[A-Za-z]:\\"#)
    private static let stackFrames = [
        regex(#"^\s*at\s+\S[^\n(:]*[(:]"#),  // Java, JavaScript; the class excludes the terminator, so no backtracking
        regex(#"^\s*File ".+", line \d+"#),  // Python
        regex(#"^\s*#\d+\s+0x[0-9a-fA-F]+"#),  // native backtraces
        regex(#"^\s*\d+\s+\S+\s+0x[0-9a-fA-F]+\s"#),  // Apple crash logs
    ]
    private static let stackHeaders = regex(
        #"(?m)^(?:Traceback \(most recent call last\):|Exception in thread|Fatal error:|Uncaught \w*(?:Error|Exception)|PHP (?:Fatal|Warning))"#
    )
    private static let codeKeywords = regex(
        #"\b(?:func|function|def|class|struct|enum|interface|import|return|const|let|var|public|private|namespace|use|fn|impl)\b|=>|->|::|<\?php|</?[a-z][a-z0-9]*[ >]"#
    )

    /// Pastes beyond this size are plain text: classifying them costs time inside the capture path
    /// and no rule here is meant for megabyte-sized content.
    static let maximumClassifiedBytes = 1_048_576
    /// Line-based rules look at the start of the text only.
    static let sampleCharacters = 32 * 1024
    /// Real stack frames are short; longer lines are skipped by the frame rules.
    static let maximumFrameLineLength = 2_000

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
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let frames = lines.filter { line in
            line.count <= maximumFrameLineLength && stackFrames.contains { matches($0, line) }
        }
        if frames.count >= 2 { return true }
        return matches(stackHeaders, text) && lines.count >= 2
    }

    private static func isCommand(_ text: String) -> Bool {
        let firstLine = String(text.prefix(while: { !$0.isNewline }))
        var line = firstLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("$ ") { line.removeFirst(2) }
        let word = line.prefix(while: { !$0.isWhitespace })
        guard commands.contains(String(word)) else { return false }
        // "git is a tool." is prose; a command has arguments or stands alone without a period.
        return !line.hasSuffix(".") || line.contains(" -")
    }

    private static func isCode(_ text: String, isSingleLine: Bool) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        let keywordLines = lines.filter { matches(codeKeywords, String($0)) }.count
        let punctuationLines = lines.filter { line in
            guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
            return ";{})".contains(last) || line.contains(" = ")
        }.count
        if isSingleLine {
            let looksCallLike = text.contains("(") && text.contains(")")
            return keywordLines > 0 && punctuationLines > 0 && looksCallLike
        }
        return keywordLines + punctuationLines >= 3 && lines.count >= 2
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants covered by tests, so a failure is a programmer error.
        try! NSRegularExpression(pattern: pattern)
    }
}

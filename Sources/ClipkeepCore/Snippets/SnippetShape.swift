import Foundation

/// The merge key of a snippet: its text with the variable values (paths, numbers, strings, URLs,
/// addresses, hashes) masked, so near-copies of one command share a shape. It is pure and
/// deterministic and runs on anonymised text; anonymiser placeholders stay literal.
public enum SnippetShape {
    /// The version of the rules below. A change of the rules bumps it, so stored keys made by
    /// older rules can be recomputed.
    public static let version = 1

    /// The normalised text. Lines are shaped one by one and keep their count and order. Any
    /// line break counts, `\r\n` (one `Character`) included.
    public static func of(_ text: String, language: SnippetLanguage) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(Array.init)
        let shaped: [String] =
            switch language {
            case .shell: lines.map(ShellShape.line)
            case .sql: lines.map(SQLShape.line)
            case .yaml: lines.map(YAMLShape.line)
            }
        return shaped.joined(separator: "\n")
    }

    /// The merge key: the hash of the shape together with the rule version and the language.
    public static func hash(of text: String, language: SnippetLanguage) -> String {
        ContentHashing.exactHash("\(version):\(language.rawValue):\(of(text, language: language))")
    }
}

/// Kind tokens. The marker cannot occur in captured text, so a token never equals a placeholder
/// or a literal word.
private enum ShapeToken {
    static let path = "\u{1}path"
    static let number = "\u{1}num"
    static let string = "\u{1}str"
    static let url = "\u{1}url"
    static let address = "\u{1}ip"
    static let hash = "\u{1}hash"
    static let bool = "\u{1}bool"
    /// A plain word that is a value by its position, such as the host of `ssh` or the user of
    /// `sudo -u`.
    static let value = "\u{1}val"
}

/// Character tests shared by the scanners. Only ASCII counts, so the rules do not depend on
/// Unicode tables.
private enum Characters {
    static func isDigit(_ character: Character) -> Bool { ("0"..."9").contains(character) }
    static func isHexDigit(_ character: Character) -> Bool {
        character.isASCII && character.isHexDigit
    }
    static func isLetter(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("A"..."Z").contains(character)
    }
    static func isIdentifier(_ character: Character) -> Bool {
        isLetter(character) || isDigit(character) || character == "_"
    }

    /// The length of an anonymiser placeholder such as `<OPENAI_API_KEY>` at `index`, if any.
    static func placeholderLength(in characters: [Character], at index: Int) -> Int? {
        guard index < characters.count, characters[index] == "<" else { return nil }
        var end = index + 1
        guard end < characters.count, ("A"..."Z").contains(characters[end]) else { return nil }
        while end < characters.count,
            ("A"..."Z").contains(characters[end]) || isDigit(characters[end])
                || characters[end] == "_"
        {
            end += 1
        }
        guard end < characters.count, characters[end] == ">" else { return nil }
        return end + 1 - index
    }

    /// Whether `characters` continues with `text` at `index`. It compares in place, since the
    /// scanners ask for every character of the line.
    static func hasPrefix(_ text: String, in characters: [Character], at index: Int) -> Bool {
        var position = index
        for expected in text {
            guard position < characters.count, characters[position] == expected else {
                return false
            }
            position += 1
        }
        return true
    }

    static func isPlaceholder(_ text: String) -> Bool {
        let characters = Array(text)
        return placeholderLength(in: characters, at: 0) == characters.count
    }

    /// `text` without its surrounding quotes when the whole text is one quoted string.
    static func quotedContent(_ text: String) -> String? {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'",
            text.last == first
        else { return nil }
        return String(text.dropFirst().dropLast())
    }

    static func isNumber(_ text: String) -> Bool {
        var body = Substring(text)
        if let sign = body.first, sign == "-" || sign == "+" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !body.isEmpty, parts.count <= 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(isDigit) } && body.contains(where: isDigit)
    }
}

/// Shell: values in arguments are masked. Kept literal, because a difference there is a
/// different command: program names (the first word of each command, and the command or script
/// a wrapper such as `sudo`, `env` or `python3` runs), flags, operators, code (the argument of
/// `-c`, `-e`, `--command`, `--eval`, `--exec`, `eval` and `exec`, and any word holding `$( … )`,
/// backticks or `<( … )`) and everything after the host of `ssh`. Redirections of stderr, to
/// `/dev/null` and fd duplications are dropped; any other keeps its operator and a masked target.
private enum ShellShape {
    private static let codeArgumentWords: Set<String> = ["eval", "exec"]
    private static let codeLongFlags: Set<String> = ["--command", "--eval", "--exec"]
    /// Programs that run the command or script named by their first operand.
    private static let wrappers: Set<String> = [
        "sudo", "doas", "env", "nohup", "time", "nice", "command", "builtin", "xargs", "watch",
        "bash", "sh", "zsh", "python", "python3", "node", "ruby", "perl",
    ]
    /// Wrapper flags whose argument is a value, not the command that runs.
    private static let wrapperValueFlags: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-D", "-R", "-T"],
        "doas": ["-u", "-C"],
        "env": ["-u", "-C", "-P"],
        "nice": ["-n"],
        "xargs": ["-I", "-n", "-P", "-L", "-d", "-s", "-E", "-a"],
        "watch": ["-n"],
        "time": ["-f", "-o"],
    ]
    /// `ssh` flags that take an argument, so the host is the first operand after them.
    private static let sshValueFlags: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o",
        "-p", "-Q", "-R", "-S", "-W", "-w",
    ]

    /// What the next operand of the current command is.
    private enum Expecting {
        case arguments
        /// The command a wrapper runs.
        case command(wrapper: String)
        case sshHost
        /// The remote command of `ssh`.
        case literalRest
    }

    /// What the word after a flag is.
    private enum Pending {
        case code
        case value
    }

    /// `-c` alone or in a cluster of short flags (`-lc`), `-e` alone or ending one (`-ne`), the
    /// long code flags, `eval` and `exec`: the next word is code.
    private static func takesCodeArgument(_ word: String) -> Bool {
        if codeArgumentWords.contains(word) || codeLongFlags.contains(word) { return true }
        guard word.hasPrefix("-"), !word.hasPrefix("--") else { return false }
        let flags = word.dropFirst()
        guard !flags.isEmpty, flags.allSatisfy(Characters.isLetter) else { return false }
        return flags.contains("c") || flags.last == "e"
    }

    /// `--command=…`, `--eval=…`, `--exec=…`: the word carries its code.
    private static func isCodeAssignment(_ word: String) -> Bool {
        codeLongFlags.contains { word.hasPrefix("\($0)=") }
    }

    /// Whether a word holds code: a command or process substitution or backticks.
    static func holdsCode(_ word: String) -> Bool {
        word.contains("$(") || word.contains("`") || word.contains("<(") || word.contains(">(")
    }

    private static func expecting(after program: String) -> Expecting {
        let name = program.split(separator: "/").last.map(String.init) ?? program
        if wrappers.contains(name) { return .command(wrapper: name) }
        return name == "ssh" ? .sshHost : .arguments
    }

    static func line(_ characters: [Character]) -> String {
        var scanner = ShellScanner(characters: characters)
        var output: [String] = []
        var atCommandStart = true
        var expecting = Expecting.arguments
        var pending: Pending?
        while let token = scanner.next() {
            switch token {
            case .redirect(let symbol, let target, let duplicates):
                if let kept = redirect(symbol, target: target, duplicates: duplicates) {
                    output.append(kept)
                }
            case .separator(let text):
                output.append(text)
                atCommandStart = true
                expecting = .arguments
                pending = nil
            case .literal(let text):
                output.append(text)
            case .word(let word):
                if let current = pending {
                    pending = nil
                    switch current {
                    case .code:
                        output.append(word)
                        expecting = .arguments
                    case .value:
                        output.append(value(word))
                    }
                    continue
                }
                if isCodeAssignment(word) {
                    output.append(word)
                    continue
                }
                if case .literalRest = expecting {
                    output.append(word)
                    continue
                }
                if atCommandStart, isAssignment(word) {
                    // `FOO=1 cmd`: the program follows the assignments.
                    output.append(masked(word))
                    continue
                }
                if atCommandStart {
                    atCommandStart = false
                    output.append(word)
                    expecting = Self.expecting(after: word)
                    if takesCodeArgument(word) { pending = .code }
                    continue
                }
                if word.hasPrefix("-") {
                    output.append(masked(word))
                    pending = pendingAfter(flag: word, expecting: expecting)
                    continue
                }
                switch expecting {
                case .command:
                    if isAssignment(word) {
                        output.append(masked(word))
                        continue
                    }
                    output.append(word)
                    expecting = Self.expecting(after: word)
                    if takesCodeArgument(word) { pending = .code }
                case .sshHost:
                    output.append(value(word))
                    expecting = .literalRest
                case .arguments, .literalRest:
                    output.append(masked(word))
                }
            }
        }
        return output.joined(separator: " ")
    }

    private static func pendingAfter(flag: String, expecting: Expecting) -> Pending? {
        switch expecting {
        case .sshHost:
            return sshValueFlags.contains(flag) ? .value : nil
        case .command(let wrapper):
            if wrapperValueFlags[wrapper]?.contains(flag) == true { return .value }
            return takesCodeArgument(flag) ? .code : nil
        case .arguments, .literalRest:
            return takesCodeArgument(flag) ? .code : nil
        }
    }

    /// A word that is a value by its position: masked like any value, and a plain word becomes
    /// a value token too.
    private static func value(_ word: String) -> String {
        let shaped = masked(word)
        guard shaped == word, !Characters.isPlaceholder(word), !holdsCode(word) else {
            return shaped
        }
        return ShapeToken.value
    }

    /// The redirection as it stays in the shape, or nil when it is dropped: stderr (`2>`,
    /// `2>>`), fd duplications (`2>&1`, `>&2`) and anything sent to or read from `/dev/null`.
    private static func redirect(_ symbol: String, target: String?, duplicates: Bool) -> String? {
        if duplicates || symbol.hasPrefix("2>") { return nil }
        guard let target else { return symbol }
        if (Characters.quotedContent(target) ?? target) == "/dev/null" { return nil }
        let kept =
            Characters.isPlaceholder(target) || holdsCode(target) ? target : ShapeToken.path
        return "\(symbol) \(kept)"
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { Characters.isLetter($0) || $0 == "_" } == true
            && name.allSatisfy(Characters.isIdentifier)
    }

    /// Masks the value of a word; for `name=value` and `--flag=value` only the value.
    private static func masked(_ word: String) -> String {
        if Characters.quotedContent(word) == nil, let equals = word.firstIndex(of: "=") {
            let name = word[..<equals]
            let isName =
                !name.isEmpty
                && name.drop(while: { $0 == "-" }).allSatisfy {
                    Characters.isIdentifier($0) || $0 == "-" || $0 == "."
                }
            if isName {
                let value = String(word[word.index(after: equals)...])
                return "\(name)=\(value.isEmpty ? value : classified(value))"
            }
        }
        return classified(word)
    }

    private static func classified(_ word: String) -> String {
        if Characters.isPlaceholder(word) { return word }
        // Code is never a value: `"$(rm -rf /)"` and `"$(ls)"` must not share a shape.
        if holdsCode(word) { return word }
        if let content = Characters.quotedContent(word) {
            return Characters.isPlaceholder(content) ? word : ShapeToken.string
        }
        // Flags, numeric ones such as `-9` included, are structure, not values.
        if word.hasPrefix("-") { return word }
        if Characters.isNumber(word) { return ShapeToken.number }
        if isURL(word) { return ShapeToken.url }
        if isAddress(word) { return ShapeToken.address }
        if isHash(word) { return ShapeToken.hash }
        if word == "~" || word.contains("/") { return ShapeToken.path }
        return word
    }

    private static func isURL(_ word: String) -> Bool {
        guard let separator = word.range(of: "://") else { return false }
        let scheme = word[..<separator.lowerBound]
        return scheme.first.map(Characters.isLetter) == true
            && scheme.allSatisfy { Characters.isIdentifier($0) || "+.-".contains($0) }
    }

    private static func isAddress(_ word: String) -> Bool {
        var body = Substring(word)
        if let slash = body.lastIndex(of: "/") {
            guard body[body.index(after: slash)...].allSatisfy(Characters.isDigit) else {
                return false
            }
            body = body[..<slash]
        }
        let octets = body.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 {
            var last = octets[3]
            if let colon = last.firstIndex(of: ":") {
                guard last[last.index(after: colon)...].allSatisfy(Characters.isDigit) else {
                    return false
                }
                last = last[..<colon]
            }
            return (octets.dropLast() + [last]).allSatisfy {
                (1...3).contains($0.count) && $0.allSatisfy(Characters.isDigit)
            }
        }
        let bare = body.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare.filter { $0 == ":" }.count >= 2
            && bare.allSatisfy { Characters.isHexDigit($0) || $0 == ":" }
    }

    /// A long hex string (commit, digest) or a long base64 or URL-safe token.
    private static func isHash(_ word: String) -> Bool {
        if word.count >= 7, word.allSatisfy(Characters.isHexDigit),
            word.contains(where: Characters.isDigit)
        {
            return true
        }
        let body = word.prefix { $0 != "=" }
        guard body.count >= 20, word.dropFirst(body.count).allSatisfy({ $0 == "=" }),
            body.allSatisfy({ Characters.isIdentifier($0) || "+/-".contains($0) })
        else { return false }
        return body.contains(where: { ("a"..."z").contains($0) })
            && body.contains(where: { ("A"..."Z").contains($0) })
            && body.contains(where: Characters.isDigit)
    }
}

/// Splits one shell line into words, command separators and redirections. Quotes, `$( … )` and
/// backticks stay inside their word.
private struct ShellScanner {
    enum Token {
        case word(String)
        case separator(String)
        /// Kept in the shape but does not start a new command (heredoc markers, comments).
        case literal(String)
        /// The operator, its target word if any, and whether it duplicates an fd (`2>&1`).
        case redirect(String, target: String?, duplicates: Bool)
    }

    private static let separators = ["||", "&&", ";;", "|&", "|", "&", ";"]

    let characters: [Character]
    private var index = 0

    init(characters: [Character]) {
        self.characters = characters
    }

    mutating func next() -> Token? {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        guard index < characters.count else { return nil }
        let start = index
        let token = scanToken()
        // Every step must consume input, or the caller's loop never ends. A rule that does not
        // is a bug; the character it stopped on is kept as it is instead.
        guard index > start else {
            index = start + 1
            return .literal(String(characters[start]))
        }
        return token
    }

    private mutating func scanToken() -> Token {
        if characters[index] == "#" {
            defer { index = characters.count }
            return .literal(String(characters[index...]))
        }
        if hasPrefix("<<") {
            let length = hasPrefix("<<<") ? 3 : 2
            index += length
            return .literal(String(repeating: "<", count: length))
        }
        if let length = redirectOperatorLength() {
            let symbol = String(characters[index..<index + length])
            index += length
            return redirect(symbol, afterAmpersand: symbol.hasSuffix("&"))
        }
        if let separator = Self.separators.first(where: hasPrefix) {
            index += separator.count
            return .separator(separator)
        }
        return .word(readWord())
    }

    private func hasPrefix(_ text: String) -> Bool {
        Characters.hasPrefix(text, in: characters, at: index)
    }

    /// `>`, `>>`, `2>`, `2>&`, `&>`, `<` and friends; nil for placeholders and `<(`/`>(`.
    private func redirectOperatorLength() -> Int? {
        if Characters.placeholderLength(in: characters, at: index) != nil { return nil }
        var end = index
        if characters[end] == "&" {
            end += 1
        } else {
            while end < characters.count, Characters.isDigit(characters[end]) { end += 1 }
        }
        guard end < characters.count, characters[end] == ">" || characters[end] == "<" else {
            return nil
        }
        if characters[index] == "&", characters[end] != ">" { return nil }
        end += 1
        if end < characters.count, characters[end] == "(" { return nil }
        if end < characters.count, ">&|".contains(characters[end]) { end += 1 }
        return end - index
    }

    /// Reads what follows a redirection operator: the fd of a duplication such as `>&2`, or the
    /// target word, if there is one before the next separator.
    private mutating func redirect(_ symbol: String, afterAmpersand: Bool) -> Token {
        if afterAmpersand {
            let start = index
            while index < characters.count,
                Characters.isDigit(characters[index]) || characters[index] == "-"
            {
                index += 1
            }
            if index > start { return .redirect(symbol, target: nil, duplicates: true) }
        }
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        guard index < characters.count, !Self.separators.contains(where: hasPrefix) else {
            return .redirect(symbol, target: nil, duplicates: afterAmpersand)
        }
        let target = readWord()
        return .redirect(symbol, target: target.isEmpty ? nil : target, duplicates: false)
    }

    private mutating func readWord() -> String {
        var word = ""
        while index < characters.count {
            let character = characters[index]
            if character == "<" || character == ">", index + 1 < characters.count,
                characters[index + 1] == "("
            {
                // Process substitution, `<( … )` or `>( … )`: one word, like `$( … )`.
                let start = index
                skipParenthesised()
                word += String(characters[start..<index])
                continue
            }
            if character.isWhitespace || "|&;>".contains(character) { break }
            if character == "<" {
                guard let length = Characters.placeholderLength(in: characters, at: index) else {
                    break
                }
                word += String(characters[index..<index + length])
                index += length
                continue
            }
            let start = index
            switch character {
            case "'": skipQuoted(closing: "'", escapes: false)
            case "\"": skipQuoted(closing: "\"", escapes: true)
            case "`": skipQuoted(closing: "`", escapes: true)
            case "\\": index = min(index + 2, characters.count)
            case "$" where index + 1 < characters.count && characters[index + 1] == "(":
                skipParenthesised()
            default: index += 1
            }
            word += String(characters[start..<index])
        }
        return word
    }

    private mutating func skipQuoted(closing: Character, escapes: Bool) {
        index += 1
        while index < characters.count {
            if escapes, characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == closing { break }
            index += 1
        }
        index = min(index + 1, characters.count)
    }

    /// Skips `$( … )`, `<( … )` or `>( … )` from its first character to the matching `)`, or to
    /// the end of the line when it is not closed.
    private mutating func skipParenthesised() {
        // The `$`, `<` or `>` before the opening parenthesis.
        index += 1
        var depth = 0
        while index < characters.count {
            switch characters[index] {
            case "(": depth += 1
            case ")": depth -= 1
            case "'":
                skipQuoted(closing: "'", escapes: false)
                continue
            case "\"":
                skipQuoted(closing: "\"", escapes: true)
                continue
            case "`":
                skipQuoted(closing: "`", escapes: true)
                continue
            case "\\":
                index = min(index + 2, characters.count)
                continue
            default: break
            }
            index += 1
            if depth == 0 { return }
        }
    }
}

/// SQL: string and numeric literals are masked, keywords are lower-cased, whitespace is
/// normalised. Identifiers, operators and structure stay.
private enum SQLShape {
    private static let keywords: Set<String> = [
        "add", "all", "alter", "analyze", "and", "any", "as", "asc", "begin", "between", "by",
        "case", "cast", "check", "column", "commit", "constraint", "create", "cross", "database",
        "default", "delete", "desc", "describe", "distinct", "drop", "else", "end", "exists",
        "explain", "false", "foreign", "from", "full", "grant", "group", "having", "if", "ilike",
        "in", "index", "inner", "insert", "intersect", "interval", "into", "is", "join", "key",
        "left", "like", "limit", "natural", "not", "null", "offset", "on", "or", "order", "outer",
        "over", "partition", "primary", "references", "rename", "replace", "returning", "revoke",
        "right", "rollback", "schema", "select", "set", "show", "table", "then", "to",
        "transaction", "true", "truncate", "union", "unique", "update", "use", "using", "values",
        "view", "when", "where", "window", "with",
    ]
    private static let operators = ["<=", ">=", "<>", "!=", "==", "||", "::", "->>", "->"]

    static func line(_ characters: [Character]) -> String {
        var output: [String] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            let start = index
            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                output.append(String(characters[index...]))
                break
            }
            if let length = Characters.placeholderLength(in: characters, at: index) {
                index += length
                output.append(String(characters[start..<index]))
            } else if character == "'" {
                index = quotedEnd(characters, from: index, closing: "'")
                let literal = String(characters[start..<index])
                let content = Characters.quotedContent(literal) ?? ""
                output.append(Characters.isPlaceholder(content) ? literal : ShapeToken.string)
            } else if character == "\"" || character == "`" {
                index = quotedEnd(characters, from: index, closing: character)
                output.append(String(characters[start..<index]))
            } else if Characters.isDigit(character) {
                // A number, including decimals and hex such as `0x1F`.
                while index < characters.count,
                    Characters.isIdentifier(characters[index]) || characters[index] == "."
                {
                    index += 1
                }
                output.append(word(String(characters[start..<index])))
            } else if Characters.isIdentifier(character) || character == "$" || character == "@" {
                while index < characters.count,
                    Characters.isIdentifier(characters[index]) || "$@".contains(characters[index])
                {
                    index += 1
                }
                output.append(word(String(characters[start..<index])))
            } else if let symbol = operators.first(where: { matches($0, characters, at: index) }) {
                index += symbol.count
                output.append(symbol)
            } else {
                index += 1
                output.append(String(character))
            }
        }
        return output.joined(separator: " ")
    }

    private static func word(_ word: String) -> String {
        if Characters.isNumber(word) || isHexNumber(word) { return ShapeToken.number }
        let lowered = word.lowercased()
        return keywords.contains(lowered) ? lowered : word
    }

    private static func isHexNumber(_ word: String) -> Bool {
        let lowered = word.lowercased()
        return lowered.hasPrefix("0x") && lowered.count > 2
            && lowered.dropFirst(2).allSatisfy(Characters.isHexDigit)
    }

    private static func matches(_ text: String, _ characters: [Character], at index: Int) -> Bool {
        Characters.hasPrefix(text, in: characters, at: index)
    }

    /// The index after the closing quote; a doubled quote is an escaped one.
    private static func quotedEnd(_ characters: [Character], from start: Int, closing: Character)
        -> Int
    {
        var index = start + 1
        while index < characters.count {
            if characters[index] == closing {
                if index + 1 < characters.count, characters[index + 1] == closing {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return characters.count
    }
}

/// YAML: scalar values become string, number or bool tokens. Indentation, list markers, keys,
/// comments, anchors, tags and block indicators stay.
private enum YAMLShape {
    private static let bools: Set<String> = ["true", "false", "yes", "no", "on", "off"]
    private static let nulls: Set<String> = ["null", "~"]

    static func line(_ characters: [Character]) -> String {
        let indentation = String(characters.prefix { $0 == " " || $0 == "\t" })
        let trimmed = String(characters.dropFirst(indentation.count))
            .trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" || trimmed == "..." {
            return indentation + trimmed
        }
        // Slices, not copies: a line of many `- ` markers must stay linear.
        var rest = Substring(trimmed)
        var parts: [String] = []
        while rest == "-" || rest.hasPrefix("- ") {
            parts.append("-")
            rest = rest.dropFirst().drop(while: isBlank)
        }
        if !rest.isEmpty { parts.append(entry(String(rest))) }
        return indentation + parts.joined(separator: " ")
    }

    private static func isBlank(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
    }

    /// `key: value` keeps the key and masks the value; anything else is a scalar.
    private static func entry(_ text: String) -> String {
        guard let colon = keySeparator(in: text) else { return value(text) }
        let key = text[..<colon]
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? "\(key):" : "\(key): \(value(rest))"
    }

    /// The colon that ends a mapping key: outside quotes and followed by a space or the end.
    private static func keySeparator(in text: String) -> String.Index? {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return nil
            } else if character == ":", next == text.endIndex || text[next] == " " {
                return index
            }
            index = next
        }
        return nil
    }

    private static func value(_ text: String) -> String {
        let (body, comment) = splitComment(text)
        let shaped = node(body.trimmingCharacters(in: .whitespaces))
        guard let comment else { return shaped }
        return shaped.isEmpty ? comment : "\(shaped) \(comment)"
    }

    /// Anchors and tags (`&a`, `!tag`) stay, then the content is masked. The markers are read
    /// in a loop, not by recursion, so a long run of them cannot exhaust the stack.
    private static func node(_ text: String) -> String {
        var parts: [String] = []
        var rest = Substring(text)
        while let first = rest.first, first == "&" || first == "!" {
            let marker = rest.prefix { $0 != " " }
            parts.append(String(marker))
            rest = rest.dropFirst(marker.count).drop(while: isBlank)
        }
        if let content = content(String(rest)) { parts.append(content) }
        return parts.joined(separator: " ")
    }

    private static func content(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        if first == "|" || first == ">" || first == "*" { return text }
        if first == "[" || first == "{" { return flow(text) }
        return scalar(text)
    }

    /// Masks the scalars of a flow collection such as `[a, b]` or `{k: v}`.
    private static func flow(_ text: String) -> String {
        var output = ""
        var segment = ""
        func flush() {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { output += entry(trimmed) }
            segment = ""
        }
        for character in text {
            if "[]{},".contains(character) {
                flush()
                output.append(character)
            } else {
                segment.append(character)
            }
        }
        flush()
        return output
    }

    private static func scalar(_ text: String) -> String {
        if Characters.isPlaceholder(text) { return text }
        if let content = Characters.quotedContent(text) {
            return Characters.isPlaceholder(content) ? text : ShapeToken.string
        }
        let lowered = text.lowercased()
        if nulls.contains(lowered) { return lowered }
        if bools.contains(lowered) { return ShapeToken.bool }
        if Characters.isNumber(text) { return ShapeToken.number }
        return ShapeToken.string
    }

    /// Splits off a ` #` comment outside quotes.
    private static func splitComment(_ text: String) -> (String, String?) {
        var quote: Character?
        var previous: Character = " "
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == " " {
                return (String(text[..<index]), String(text[index...]))
            }
            previous = character
        }
        return (text, nil)
    }
}

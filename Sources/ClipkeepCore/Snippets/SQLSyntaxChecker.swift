/// The SQL part of `SnippetValidator`: unterminated strings, quoted identifiers and block comments,
/// unbalanced parentheses, and statements whose verb lacks the structure it needs (`INSERT`
/// without a source, `UPDATE` without `SET`). Dialect-specific input (`#` comments,
/// backslash-escaped quotes, nested comments, an empty select list, unknown verbs, …) is
/// `notChecked`.
struct SQLSyntaxChecker {
    /// What one statement looked like, collected while scanning it.
    private struct Statement {
        var tokenCount = 0
        /// The upper-cased first word, or nil when the statement starts with something else.
        var verb: String?
        /// The upper-cased second token; empty for a token that is not a word.
        var second: String?
        var hasSet = false
        var hasInsertSource = false
    }

    /// Verbs whose statements the checker understands. Only some have structural rules.
    private static let knownVerbs: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "WITH", "CREATE", "ALTER", "DROP", "TRUNCATE",
        "BEGIN", "COMMIT", "ROLLBACK",
    ]
    private static let insertSources: Set<String> = [
        "VALUES", "VALUE", "SELECT", "SET", "DEFAULT", "TABLE", "WITH", "EXEC", "EXECUTE", "FORMAT",
    ]
    /// Oracle's `q'[…]'` quoting allows any character, quotes included, between the brackets.
    private static let alternativeQuotePrefixes: Set<String> = ["Q", "NQ"]
    private static let longestKeyword = 12
    private static let longestDollarTag = 64

    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private var statement = Statement()
    private var sawStatement = false
    /// A statement with an unknown verb or a dialect-dependent form such as an empty select list.
    private var sawUnmodelledStatement = false
    private var structureHint: String?

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func run() throws(SyntaxProblem) -> SnippetCheck {
        while index < bytes.count {
            let start = index
            try step()
            guard index > start else {
                assertionFailure("The SQL check made no progress")
                throw .notChecked
            }
        }
        closeStatement()
        if depth > 0 { throw .invalid("Klammer ( nicht geschlossen") }
        // An unknown verb hints at a dialect or a procedure body, where statements may not split
        // the way this checker assumes; only the lexical findings above are certain there.
        if sawUnmodelledStatement || !sawStatement { return .notChecked }
        if let structureHint { throw .invalid(structureHint) }
        return .valid
    }

    private mutating func step() throws(SyntaxProblem) {
        let byte = bytes[index]
        switch byte {
        case _ where ASCII.isWhitespace(byte): index += 1
        case ASCII.dash where bytes.byte(at: index + 1) == ASCII.dash:
            while index < bytes.count && bytes[index] != ASCII.lineFeed { index += 1 }
        case ASCII.slash where bytes.byte(at: index + 1) == ASCII.star: try skipBlockComment()
        case ASCII.hash: throw .notChecked
        case ASCII.singleQuote:
            try skipQuoted(closing: byte, hint: "Anführungszeichen ' nicht geschlossen")
        case ASCII.doubleQuote:
            try skipQuoted(closing: byte, hint: "Anführungszeichen \" nicht geschlossen")
        case ASCII.backtick:
            try skipQuoted(closing: byte, hint: "Backtick ` nicht geschlossen")
        case ASCII.openBracket: try skipBracketed()
        case ASCII.dollar: try dollar()
        case ASCII.openParen:
            depth += 1
            record(word: nil)
            index += 1
        case ASCII.closeParen:
            guard depth > 0 else { throw .invalid("Klammer ) ohne öffnende Klammer") }
            depth -= 1
            record(word: nil)
            index += 1
        case ASCII.semicolon:
            // `;` inside parentheses only appears in dialect-specific bodies.
            guard depth == 0 else { throw .notChecked }
            closeStatement()
            index += 1
        case _ where ASCII.isIdentifier(byte): try word()
        default:
            record(word: nil)
            index += 1
        }
    }

    private mutating func word() throws(SyntaxProblem) {
        var end = index
        while end < bytes.count && (ASCII.isIdentifier(bytes[end]) || bytes[end] == ASCII.dollar) {
            end += 1
        }
        let isShort = end - index <= Self.longestKeyword
        let text = isShort ? ASCII.uppercased(bytes[index..<end]) : ""
        if bytes.byte(at: end) == ASCII.singleQuote && Self.alternativeQuotePrefixes.contains(text)
        {
            throw .notChecked
        }
        record(word: text)
        index = end
    }

    private mutating func record(word: String?) {
        statement.tokenCount += 1
        if statement.tokenCount == 1 {
            statement.verb = word
        } else if statement.tokenCount == 2 {
            statement.second = word ?? ""
        }
        guard let word else { return }
        if word == "SET" { statement.hasSet = true }
        if Self.insertSources.contains(word) { statement.hasInsertSource = true }
    }

    private mutating func closeStatement() {
        defer { statement = Statement() }
        guard statement.tokenCount > 0 else { return }
        sawStatement = true
        guard let verb = statement.verb, Self.knownVerbs.contains(verb) else {
            sawUnmodelledStatement = true
            return
        }
        // PostgreSQL 9.4+ accepts an empty select list (`SELECT;`, `SELECT FROM t`), other
        // dialects reject it, so it gets no verdict.
        if verb == "SELECT"
            && (statement.second == nil || statement.second == "FROM"
                || statement.second == "WHERE")
        {
            sawUnmodelledStatement = true
            return
        }
        guard structureHint == nil else { return }
        switch verb {
        case "INSERT":
            if !statement.hasInsertSource { structureHint = "INSERT ohne VALUES oder SELECT" }
        case "UPDATE":
            if statement.second != "STATISTICS" && !statement.hasSet {
                structureHint = "UPDATE ohne SET"
            }
        default: break
        }
    }

    /// Skips a string or quoted identifier, where a doubled closing quote stands for itself.
    /// A backslash before the quote means different things per dialect, so it is not modelled.
    private mutating func skipQuoted(closing quote: UInt8, hint: String) throws(SyntaxProblem) {
        var position = index + 1
        while position < bytes.count {
            let byte = bytes[position]
            if byte == ASCII.backslash && bytes.byte(at: position + 1) == quote {
                throw .notChecked
            }
            if byte == quote {
                if bytes.byte(at: position + 1) == quote {
                    position += 2
                    continue
                }
                index = position + 1
                record(word: nil)
                return
            }
            position += 1
        }
        throw .invalid(hint)
    }

    private mutating func skipBlockComment() throws(SyntaxProblem) {
        var position = index + 2
        while position < bytes.count {
            let byte = bytes[position]
            let next = bytes.byte(at: position + 1)
            if byte == ASCII.star && next == ASCII.slash {
                index = position + 2
                return
            }
            // PostgreSQL nests block comments, other dialects do not.
            if byte == ASCII.slash && next == ASCII.star { throw .notChecked }
            position += 1
        }
        throw .invalid("Kommentar /* nicht geschlossen")
    }

    /// Skips `[…]`: an identifier in SQL Server, an array subscript elsewhere. Quotes inside mean
    /// different things in the two, so they are not modelled.
    private mutating func skipBracketed() throws(SyntaxProblem) {
        var position = index + 1
        while position < bytes.count && bytes[position] != ASCII.closeBracket {
            let byte = bytes[position]
            if byte == ASCII.singleQuote || byte == ASCII.doubleQuote || byte == ASCII.lineFeed {
                throw .notChecked
            }
            position += 1
        }
        guard position < bytes.count else { throw .notChecked }
        index = position + 1
        record(word: nil)
    }

    /// `$1` parameters and PostgreSQL dollar quoting (`$$…$$`, `$tag$…$tag$`).
    private mutating func dollar() throws(SyntaxProblem) {
        var tagEnd = index + 1
        while tagEnd < bytes.count && tagEnd - index <= Self.longestDollarTag
            && (ASCII.isLetter(bytes[tagEnd]) || bytes[tagEnd] == ASCII.underscore
                || (tagEnd > index + 1 && ASCII.isDigit(bytes[tagEnd])))
        {
            tagEnd += 1
        }
        guard bytes.byte(at: tagEnd) == ASCII.dollar else {
            index += 1
            record(word: nil)
            return
        }
        let tag = bytes[index...tagEnd]
        var position = tagEnd + 1
        while position + tag.count <= bytes.count {
            if bytes[position] == ASCII.dollar
                && bytes[position..<(position + tag.count)].elementsEqual(tag)
            {
                index = position + tag.count
                record(word: nil)
                return
            }
            position += 1
        }
        throw .notChecked
    }
}

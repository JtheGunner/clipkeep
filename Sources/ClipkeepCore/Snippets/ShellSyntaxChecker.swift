/// The shell part of `SnippetValidator`: unterminated quotes, unbalanced `(`, `{`, backticks,
/// `$(`, `$((` and `${`, a `|`, `&&` or `||` without a following command, `;;` outside `case`, and
/// unterminated heredocs. Functions, `case`, process substitution, here-strings, extended globs and
/// regex matches are not modelled and make the snippet `notChecked`.
struct ShellSyntaxChecker {
    private enum Frame {
        case doubleQuote, commandSubstitution, arithmetic, arithmeticParen, subshell, group,
            backtick

        var unclosedHint: String {
            switch self {
            case .doubleQuote: "Anführungszeichen \" nicht geschlossen"
            case .commandSubstitution: "„$(“ nicht geschlossen"
            case .arithmetic, .arithmeticParen: "„$((“ nicht geschlossen"
            case .subshell: "Klammer ( nicht geschlossen"
            case .group: "Klammer { nicht geschlossen"
            case .backtick: "Backtick ` nicht geschlossen"
            }
        }
    }

    private struct Heredoc {
        let delimiter: [UInt8]
        let stripsTabs: Bool

        var unclosedHint: String {
            "Heredoc „\(String(decoding: delimiter.prefix(20), as: UTF8.self))“ nicht abgeschlossen"
        }
    }

    /// Words that start constructs this checker does not model.
    private static let unmodelledKeywords: Set<String> = [
        "CASE", "ESAC", "FUNCTION", "COPROC", "SELECT",
    ]

    private let bytes: [UInt8]
    private var index = 0
    /// Changed only through `push` and `pop`, which keep `backtickDepth` in step.
    private var frames: [Frame] = []
    /// How many backtick frames are open, so no per-token work has to search `frames`.
    private var backtickDepth = 0
    /// True where a new command may start, which is the only place `{` and `}` are reserved words.
    private var isCommandPosition = true
    /// True where a new word starts, which is the only place `#` starts a comment.
    private var isWordStart = true
    /// A `|`, `&&` or `||` still waiting for the command after it.
    private var pendingOperator: String?
    private var pendingHeredoc: Heredoc?
    /// A `}` that may have been meant to close a group, so an open group is no certain error.
    private var sawAmbiguousBrace = false

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func run() throws(SyntaxProblem) -> SnippetCheck {
        while index < bytes.count {
            let start = index
            switch frames.last {
            case .doubleQuote: try stepInDoubleQuotes()
            case .arithmetic, .arithmeticParen: try stepInArithmetic()
            default: try stepInCode()
            }
            guard index > start else {
                assertionFailure("The shell check made no progress")
                throw .notChecked
            }
        }
        return try finish()
    }

    private func finish() throws(SyntaxProblem) -> SnippetCheck {
        if let frame = frames.last {
            if frame == .group && sawAmbiguousBrace { throw .notChecked }
            throw .invalid(frame.unclosedHint)
        }
        if let pendingHeredoc { throw .invalid(pendingHeredoc.unclosedHint) }
        if let pendingOperator { throw .invalid(Self.danglingHint(pendingOperator)) }
        return .valid
    }

    private static func danglingHint(_ operatorText: String) -> String {
        "„\(operatorText)“ ohne folgenden Befehl"
    }

    private mutating func push(_ frame: Frame) {
        frames.append(frame)
        if frame == .backtick { backtickDepth += 1 }
    }

    private mutating func pop() {
        if frames.removeLast() == .backtick { backtickDepth -= 1 }
    }

    private mutating func endWord() {
        isWordStart = false
        isCommandPosition = false
    }

    private mutating func startCommand() {
        isWordStart = true
        isCommandPosition = true
    }

    // MARK: - Inside double quotes

    private mutating func stepInDoubleQuotes() throws(SyntaxProblem) {
        switch bytes[index] {
        case ASCII.backslash: index += 2
        case ASCII.doubleQuote:
            pop()
            index += 1
            endWord()
        case ASCII.dollar: try stepDollar(isInCode: false)
        case ASCII.backtick:
            push(.backtick)
            index += 1
            startCommand()
        default: index += 1
        }
    }

    // MARK: - Inside $(( ))

    private mutating func stepInArithmetic() throws(SyntaxProblem) {
        switch bytes[index] {
        case ASCII.openParen:
            push(.arithmeticParen)
            index += 1
        case ASCII.closeParen:
            if frames.last == .arithmeticParen {
                pop()
                index += 1
            } else if bytes.byte(at: index + 1) == ASCII.closeParen {
                pop()
                index += 2
                endWord()
            } else {
                // `$((cmd) …)` is a command substitution that starts with a subshell: the `)`
                // closes that subshell and the rest is code inside `$(`.
                frames[frames.count - 1] = .commandSubstitution
                index += 1
                isWordStart = true
                isCommandPosition = false
            }
        case ASCII.singleQuote, ASCII.doubleQuote, ASCII.backtick: throw .notChecked
        case ASCII.dollar: try stepDollar(isInCode: false)
        default: index += 1
        }
    }

    // MARK: - Code

    private mutating func stepInCode() throws(SyntaxProblem) {
        let byte = bytes[index]
        if ASCII.isBlank(byte) || byte == ASCII.carriageReturn {
            index += 1
            isWordStart = true
            return
        }
        if byte == ASCII.lineFeed {
            index += 1
            startCommand()
            if let heredoc = pendingHeredoc {
                guard frames.isEmpty else { throw .notChecked }
                try skipHeredocBody(heredoc)
                pendingHeredoc = nil
            }
            return
        }
        if byte == ASCII.backslash && bytes.byte(at: index + 1) == ASCII.lineFeed {
            // A line continuation keeps a pending `|` or `&&` waiting for its command.
            index += 2
            return
        }
        if byte == ASCII.hash && isWordStart {
            // Inside backticks the comment rules depend on the shell's quoting pass.
            guard backtickDepth == 0 else { throw .notChecked }
            while index < bytes.count && bytes[index] != ASCII.lineFeed { index += 1 }
            return
        }
        if pendingOperator != nil && !Self.keepsOperatorPending(byte) { pendingOperator = nil }
        try stepToken(byte)
    }

    private static func keepsOperatorPending(_ byte: UInt8) -> Bool {
        byte == ASCII.closeParen || byte == ASCII.pipe || byte == ASCII.ampersand
            || byte == ASCII.semicolon || byte == ASCII.closeBrace
    }

    private mutating func stepToken(_ byte: UInt8) throws(SyntaxProblem) {
        switch byte {
        case ASCII.backslash:
            index += 2
            endWord()
        case ASCII.singleQuote:
            try skipSingleQuoted(from: index + 1, honoursEscapes: false)
            endWord()
        case ASCII.doubleQuote:
            push(.doubleQuote)
            index += 1
            endWord()
        case ASCII.backtick:
            index += 1
            if frames.last == .backtick {
                pop()
                endWord()
            } else {
                push(.backtick)
                startCommand()
            }
        case ASCII.dollar: try stepDollar(isInCode: true)
        case ASCII.openParen: try openParenthesis()
        case ASCII.closeParen: try closeParenthesis()
        case ASCII.openBrace: openBrace()
        case ASCII.closeBrace: try closeBrace()
        case ASCII.pipe: try pipe()
        case ASCII.ampersand: try ampersand()
        case ASCII.semicolon: try semicolon()
        case ASCII.less: try less()
        case ASCII.greater: try greater()
        case ASCII.equals:
            if bytes.byte(at: index + 1) == ASCII.tilde { throw .notChecked }
            index += 1
            endWord()
        default:
            if Self.isWordByte(byte) {
                try word()
            } else {
                index += 1
                endWord()
            }
        }
    }

    /// Bytes without a structural meaning that a plain word consists of.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        ASCII.isIdentifier(byte) || byte == ASCII.dash || byte == ASCII.period
            || byte == ASCII.slash || byte == ASCII.colon || byte == ASCII.comma
            || byte == ASCII.percent || byte == ASCII.plus || byte == ASCII.at
    }

    private mutating func word() throws(SyntaxProblem) {
        var end = index
        while end < bytes.count && Self.isWordByte(bytes[end]) { end += 1 }
        if isWordStart && end - index <= 8
            && Self.unmodelledKeywords.contains(ASCII.uppercased(bytes[index..<end]))
        {
            throw .notChecked
        }
        index = end
        endWord()
    }

    private mutating func skipSingleQuoted(from start: Int, honoursEscapes: Bool)
        throws(SyntaxProblem)
    {
        var position = start
        while position < bytes.count {
            let byte = bytes[position]
            if honoursEscapes && byte == ASCII.backslash {
                position += 2
                continue
            }
            if byte == ASCII.singleQuote {
                index = position + 1
                return
            }
            position += 1
        }
        throw .invalid("Anführungszeichen ' nicht geschlossen")
    }

    // MARK: - $ forms

    private mutating func stepDollar(isInCode: Bool) throws(SyntaxProblem) {
        let next = bytes.byte(at: index + 1)
        switch next {
        case ASCII.openParen:
            if bytes.byte(at: index + 2) == ASCII.openParen {
                push(.arithmetic)
                index += 3
            } else {
                push(.commandSubstitution)
                index += 2
                startCommand()
                return
            }
        case ASCII.openBrace: try skipParameterExpansion()
        case ASCII.singleQuote where isInCode:
            try skipSingleQuoted(from: index + 2, honoursEscapes: true)
        case .some(let byte) where Self.isParameterStart(byte):
            // `$#`, `$?`, `$1`, `$HOME`: consume the sigil and the first character together so the
            // character never counts as a comment or an operator.
            index += 2
        default: index += 1
        }
        endWord()
    }

    private static func isParameterStart(_ byte: UInt8) -> Bool {
        ASCII.isIdentifier(byte) || byte == ASCII.hash || byte == ASCII.question
            || byte == ASCII.dollar || byte == ASCII.exclamation || byte == ASCII.at
            || byte == ASCII.star || byte == ASCII.dash
    }

    /// Skips `${…}`. Quotes, command substitutions or a bare `{` inside are not modelled.
    private mutating func skipParameterExpansion() throws(SyntaxProblem) {
        var position = index + 2
        var depth = 1
        while position < bytes.count {
            switch bytes[position] {
            case ASCII.backslash:
                position += 2
                continue
            case ASCII.closeBrace:
                depth -= 1
                if depth == 0 {
                    index = position + 1
                    return
                }
            case ASCII.dollar:
                let next = bytes.byte(at: position + 1)
                if next == ASCII.openParen { throw .notChecked }
                if next == ASCII.openBrace {
                    depth += 1
                    position += 2
                    continue
                }
            case ASCII.openBrace, ASCII.singleQuote, ASCII.doubleQuote, ASCII.backtick:
                throw .notChecked
            default: break
            }
            position += 1
        }
        throw .invalid("„${“ nicht geschlossen")
    }

    // MARK: - Brackets

    private mutating func openParenthesis() throws(SyntaxProblem) {
        if index > 0 {
            let previous = bytes[index - 1]
            // Extended globs such as `!(*.txt)` or `@(a|b)`.
            if [ASCII.exclamation, ASCII.at, ASCII.question, ASCII.star, ASCII.plus].contains(
                previous)
            {
                throw .notChecked
            }
        }
        var next = index + 1
        while next < bytes.count && ASCII.isBlank(bytes[next]) { next += 1 }
        // `name()` defines a function.
        if bytes.byte(at: next) == ASCII.closeParen { throw .notChecked }
        push(.subshell)
        index += 1
        startCommand()
    }

    private mutating func closeParenthesis() throws(SyntaxProblem) {
        if let pendingOperator { throw .invalid(Self.danglingHint(pendingOperator)) }
        guard frames.last == .subshell || frames.last == .commandSubstitution else {
            throw .invalid("Klammer ) ohne öffnende Klammer")
        }
        pop()
        index += 1
        isWordStart = true
        isCommandPosition = false
    }

    private mutating func openBrace() {
        let next = bytes.byte(at: index + 1)
        let isStandalone = next.map(ASCII.isWhitespace) ?? false
        index += 1
        if isCommandPosition && isStandalone {
            push(.group)
            startCommand()
        } else {
            endWord()
        }
    }

    private mutating func closeBrace() throws(SyntaxProblem) {
        let next = bytes.byte(at: index + 1)
        let isStandalone =
            next.map {
                ASCII.isWhitespace($0)
                    || [
                        ASCII.semicolon, ASCII.ampersand, ASCII.pipe, ASCII.closeParen, ASCII.less,
                        ASCII.greater,
                    ].contains($0)
            } ?? true
        index += 1
        guard isWordStart && isStandalone && frames.last == .group else {
            pendingOperator = nil
            endWord()
            return
        }
        guard isCommandPosition else {
            sawAmbiguousBrace = true
            pendingOperator = nil
            endWord()
            return
        }
        if let pendingOperator { throw .invalid(Self.danglingHint(pendingOperator)) }
        pop()
        endWord()
    }

    // MARK: - Operators

    private mutating func pipe() throws(SyntaxProblem) {
        let next = bytes.byte(at: index + 1)
        let operatorText = next == ASCII.pipe ? "||" : next == ASCII.ampersand ? "|&" : "|"
        try startOperator(operatorText)
    }

    private mutating func ampersand() throws(SyntaxProblem) {
        let next = bytes.byte(at: index + 1)
        if next == ASCII.ampersand {
            try startOperator("&&")
        } else if next == ASCII.greater {
            // `&>file` redirects both streams.
            index += 2
            isWordStart = true
            isCommandPosition = false
        } else {
            if let pendingOperator { throw .invalid(Self.danglingHint(pendingOperator)) }
            index += 1
            startCommand()
        }
    }

    private mutating func startOperator(_ operatorText: String) throws(SyntaxProblem) {
        if let pendingOperator { throw .invalid(Self.danglingHint(pendingOperator)) }
        pendingOperator = operatorText
        index += operatorText.utf8.count
        startCommand()
    }

    private mutating func semicolon() throws(SyntaxProblem) {
        if let pendingOperator { throw .invalid(Self.danglingHint(pendingOperator)) }
        if bytes.byte(at: index + 1) == ASCII.semicolon {
            // Inside `(( ))` or `$( )` the pair can be arithmetic, as in `for ((;;))`.
            guard !frames.isEmpty else { throw .invalid("„;;“ außerhalb von case") }
            index += 2
        } else {
            index += 1
        }
        startCommand()
    }

    private mutating func less() throws(SyntaxProblem) {
        let next = bytes.byte(at: index + 1)
        if next == ASCII.openParen { throw .notChecked }
        if next == ASCII.less {
            if bytes.byte(at: index + 2) == ASCII.less { throw .notChecked }
            try startHeredoc()
            return
        }
        index += next == ASCII.ampersand || next == ASCII.greater ? 2 : 1
        isWordStart = true
        isCommandPosition = false
    }

    private mutating func greater() throws(SyntaxProblem) {
        let next = bytes.byte(at: index + 1)
        if next == ASCII.openParen { throw .notChecked }
        let isPair = next == ASCII.greater || next == ASCII.pipe || next == ASCII.ampersand
        index += isPair ? 2 : 1
        isWordStart = true
        isCommandPosition = false
    }

    // MARK: - Heredocs

    /// Reads `<<WORD`, `<<-WORD`, `<<'WORD'` or `<<"WORD"`; the body starts after the line ends.
    private mutating func startHeredoc() throws(SyntaxProblem) {
        // `((x << 2))` and nested heredocs are not modelled; neither are two on one line.
        guard frames.isEmpty, pendingHeredoc == nil else { throw .notChecked }
        var position = index + 2
        let stripsTabs = bytes.byte(at: position) == ASCII.dash
        if stripsTabs { position += 1 }
        while position < bytes.count && ASCII.isBlank(bytes[position]) { position += 1 }
        var delimiter: [UInt8] = []
        if let quote = bytes.byte(at: position),
            quote == ASCII.singleQuote || quote == ASCII.doubleQuote
        {
            position += 1
            while position < bytes.count && bytes[position] != quote {
                guard bytes[position] != ASCII.lineFeed else { throw .notChecked }
                delimiter.append(bytes[position])
                position += 1
            }
            guard position < bytes.count else { throw .notChecked }
            position += 1
        } else {
            if bytes.byte(at: position) == ASCII.backslash { position += 1 }
            while position < bytes.count && Self.isWordByte(bytes[position]) {
                delimiter.append(bytes[position])
                position += 1
            }
        }
        if let next = bytes.byte(at: position), !ASCII.isWhitespace(next),
            ![ASCII.semicolon, ASCII.ampersand, ASCII.pipe, ASCII.less, ASCII.greater].contains(
                next)
        {
            throw .notChecked
        }
        guard !delimiter.isEmpty else { throw .notChecked }
        pendingHeredoc = Heredoc(delimiter: delimiter, stripsTabs: stripsTabs)
        index = position
        isWordStart = true
        isCommandPosition = false
    }

    /// Skips the heredoc body that starts at `index`, leaving `index` on the line feed after the
    /// closing delimiter line (or at the end of the text).
    private mutating func skipHeredocBody(_ heredoc: Heredoc) throws(SyntaxProblem) {
        var lineStart = index
        while true {
            var lineEnd = lineStart
            while lineEnd < bytes.count && bytes[lineEnd] != ASCII.lineFeed { lineEnd += 1 }
            var contentStart = lineStart
            if heredoc.stripsTabs {
                while contentStart < lineEnd && bytes[contentStart] == ASCII.tab {
                    contentStart += 1
                }
            }
            var contentEnd = lineEnd
            if contentEnd > contentStart && bytes[contentEnd - 1] == ASCII.carriageReturn {
                contentEnd -= 1
            }
            if bytes[contentStart..<contentEnd].elementsEqual(heredoc.delimiter) {
                index = lineEnd
                return
            }
            guard lineEnd < bytes.count else { throw .invalid(heredoc.unclosedHint) }
            lineStart = lineEnd + 1
        }
    }
}

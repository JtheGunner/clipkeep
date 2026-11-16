import Foundation

public enum SnippetTokenKind: Sendable {
    case keyword
    case string
    case number
    case comment
    case op
    /// A shell variable or flag.
    case variable
    case key
    case punctuation
}

public struct SnippetToken: Sendable, Equatable {
    public let kind: SnippetTokenKind
    /// A UTF-16 range, so it maps straight onto an `NSAttributedString`.
    public let range: NSRange

    public init(kind: SnippetTokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

/// A small hand-written lexer per snippet language, used to colour the explorer's detail view.
///
/// Lexing is best effort: unknown input stays untokenised, nothing throws, and every scanner makes
/// a single forward pass, so the cost is linear in the text length. Tokens are sorted by location,
/// never overlap and stay inside the text's UTF-16 length.
public enum SnippetHighlighter {
    public static func tokens(in text: String, language: SnippetLanguage) -> [SnippetToken] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }
        switch language {
        case .shell:
            var lexer = ShellLexer(units)
            return lexer.run()
        case .sql:
            var lexer = SQLLexer(units)
            return lexer.run()
        case .yaml:
            var lexer = YAMLLexer(units)
            return lexer.run()
        }
    }
}

// MARK: - Shared scanning helpers

private enum Char {
    static let tab: UInt16 = 9
    static let newline: UInt16 = 10
    static let carriageReturn: UInt16 = 13
    static let space: UInt16 = 32
    static let doubleQuote: UInt16 = 34
    static let hash: UInt16 = 35
    static let dollar: UInt16 = 36
    static let ampersand: UInt16 = 38
    static let singleQuote: UInt16 = 39
    static let openParen: UInt16 = 40
    static let closeParen: UInt16 = 41
    static let star: UInt16 = 42
    static let plus: UInt16 = 43
    static let comma: UInt16 = 44
    static let minus: UInt16 = 45
    static let dot: UInt16 = 46
    static let slash: UInt16 = 47
    static let colon: UInt16 = 58
    static let semicolon: UInt16 = 59
    static let lessThan: UInt16 = 60
    static let equals: UInt16 = 61
    static let greaterThan: UInt16 = 62
    static let openBracket: UInt16 = 91
    static let backslash: UInt16 = 92
    static let backtick: UInt16 = 96
    static let openBrace: UInt16 = 123
    static let pipe: UInt16 = 124
    static let closeBrace: UInt16 = 125
    static let tilde: UInt16 = 126

    static func isBlank(_ unit: UInt16) -> Bool { unit == space || unit == tab }
    static func isLineBreak(_ unit: UInt16) -> Bool { unit == newline || unit == carriageReturn }
    static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }
    /// Letters, digits, underscore and every non-ASCII unit (accented letters, emoji).
    static func isWordUnit(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || isDigit(unit) || unit == 95 || unit >= 128
    }
}

private struct TokenSink {
    private(set) var tokens: [SnippetToken] = []

    mutating func add(_ kind: SnippetTokenKind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        tokens.append(
            SnippetToken(kind: kind, range: NSRange(location: start, length: end - start)))
    }
}

extension Array where Element == UInt16 {
    /// The index of the next line break at or after `index`, or the end of the text.
    fileprivate func endOfLine(from index: Int) -> Int {
        var position = index
        while position < count, !Char.isLineBreak(self[position]) { position += 1 }
        return position
    }

    /// The end of a quoted run that opens at `start`, backslash escapes honoured when `escapes` is
    /// set; an unterminated run ends at `limit`.
    fileprivate func endOfQuote(from start: Int, limit: Int, escapes: Bool) -> Int {
        let quote = self[start]
        var position = start + 1
        while position < limit {
            let unit = self[position]
            if escapes, unit == Char.backslash {
                position += 2
                continue
            }
            if unit == quote { return position + 1 }
            position += 1
        }
        return limit
    }
}

// MARK: - Shell

private struct ShellLexer {
    private let units: [UInt16]
    private var sink = TokenSink()

    init(_ units: [UInt16]) { self.units = units }

    private static let operatorUnits: Set<UInt16> = [
        Char.pipe, Char.ampersand, Char.semicolon, Char.lessThan, Char.greaterThan,
    ]
    private static let wordBreaks: Set<UInt16> = [
        Char.pipe, Char.ampersand, Char.semicolon, Char.lessThan, Char.greaterThan, Char.openParen,
        Char.closeParen, Char.doubleQuote, Char.singleQuote, Char.dollar, Char.backtick,
    ]

    mutating func run() -> [SnippetToken] {
        let count = units.count
        var index = 0
        var expectsCommand = true
        while index < count {
            let unit = units[index]
            switch unit {
            case Char.space, Char.tab, Char.carriageReturn:
                index += 1
            case Char.newline:
                expectsCommand = true
                index += 1
            case Char.hash:
                let end = units.endOfLine(from: index)
                sink.add(.comment, index, end)
                index = end
            case Char.doubleQuote, Char.singleQuote:
                let end = units.endOfQuote(
                    from: index, limit: count, escapes: unit == Char.doubleQuote)
                sink.add(.string, index, end)
                index = end
            case Char.dollar:
                index = scanDollar(at: index, expectsCommand: &expectsCommand)
            case Char.openParen, Char.openBrace:
                expectsCommand = true
                index += 1
            case Char.closeParen, Char.closeBrace, Char.backtick:
                index += 1
            case _ where Self.operatorUnits.contains(unit):
                index = scanOperator(at: index, expectsCommand: &expectsCommand)
            case Char.minus where !expectsCommand:
                let end = scanWord(from: index)
                sink.add(.variable, index, end)
                index = end
            default:
                index = scanCommandOrArgument(at: index, expectsCommand: &expectsCommand)
            }
        }
        return sink.tokens
    }

    private mutating func scanDollar(at start: Int, expectsCommand: inout Bool) -> Int {
        let count = units.count
        guard start + 1 < count else { return start + 1 }
        let next = units[start + 1]
        if next == Char.openParen {
            expectsCommand = true
            return start + 2
        }
        var end = start + 1
        if next == Char.openBrace {
            while end < count, units[end] != Char.closeBrace, units[end] != Char.newline {
                end += 1
            }
            if end < count, units[end] == Char.closeBrace { end += 1 }
        } else if Char.isWordUnit(next) {
            while end < count, Char.isWordUnit(units[end]) { end += 1 }
        } else if next == 63 || next == 33 || next == 64 || next == Char.star || next == Char.hash {
            end += 1
        } else {
            return start + 1
        }
        sink.add(.variable, start, end)
        return end
    }

    private mutating func scanOperator(at start: Int, expectsCommand: inout Bool) -> Int {
        var end = start
        while end < units.count, Self.operatorUnits.contains(units[end]) { end += 1 }
        sink.add(.op, start, end)
        let redirects = units[start..<end].contains {
            $0 == Char.lessThan || $0 == Char.greaterThan
        }
        let last = units[end - 1]
        if last == Char.pipe || last == Char.semicolon || (last == Char.ampersand && !redirects) {
            expectsCommand = true
        }
        return end
    }

    /// A word ends at whitespace or at a character that starts another construct.
    private func scanWord(from start: Int) -> Int {
        var end = start
        while end < units.count {
            let unit = units[end]
            if Char.isBlank(unit) || Char.isLineBreak(unit) || Self.wordBreaks.contains(unit) {
                break
            }
            end += unit == Char.backslash ? 2 : 1
        }
        return min(max(end, start + 1), units.count)
    }

    private mutating func scanCommandOrArgument(at start: Int, expectsCommand: inout Bool) -> Int {
        let end = scanWord(from: start)
        guard expectsCommand else { return end }
        if isAssignment(start, end) { return end }
        sink.add(.keyword, start, end)
        expectsCommand = false
        return end
    }

    /// `NAME=value` before a command leaves the command still to come.
    private func isAssignment(_ start: Int, _ end: Int) -> Bool {
        guard Char.isASCIILetter(units[start]) || units[start] == 95 else { return false }
        var position = start
        while position < end, Char.isWordUnit(units[position]) { position += 1 }
        return position < end && units[position] == Char.equals
    }
}

// MARK: - SQL

private struct SQLLexer {
    private let units: [UInt16]
    private var sink = TokenSink()

    init(_ units: [UInt16]) { self.units = units }

    private static let keywords: Set<String> = [
        "select", "from", "where", "join", "insert", "into", "values", "update", "set", "delete",
        "create", "table", "drop", "alter", "group", "order", "by", "having", "limit", "and", "or",
        "not", "null", "as", "on", "with", "union", "distinct", "case", "when", "then", "else",
        "end",
        "in", "is", "like", "exists", "if",
    ]
    private static let longestKeyword = 8
    private static let operatorUnits: Set<UInt16> = [
        Char.equals, Char.lessThan, Char.greaterThan, 33, Char.plus, Char.minus, Char.star,
        Char.slash, 37, Char.pipe, Char.ampersand, 94, Char.tilde, Char.colon,
    ]
    private static let punctuationUnits: Set<UInt16> = [
        Char.openParen, Char.closeParen, Char.comma, Char.semicolon,
    ]

    mutating func run() -> [SnippetToken] {
        let count = units.count
        var index = 0
        while index < count {
            let unit = units[index]
            if Char.isBlank(unit) || Char.isLineBreak(unit) {
                index += 1
            } else if unit == Char.minus, index + 1 < count, units[index + 1] == Char.minus {
                let end = units.endOfLine(from: index)
                sink.add(.comment, index, end)
                index = end
            } else if unit == Char.slash, index + 1 < count, units[index + 1] == Char.star {
                let end = endOfBlockComment(from: index)
                sink.add(.comment, index, end)
                index = end
            } else if unit == Char.singleQuote {
                let end = endOfSingleQuoted(from: index)
                sink.add(.string, index, end)
                index = end
            } else if unit == Char.doubleQuote || unit == Char.backtick {
                index = units.endOfQuote(from: index, limit: count, escapes: false)
            } else if Char.isDigit(unit) {
                let end = endOfNumber(from: index)
                sink.add(.number, index, end)
                index = end
            } else if Char.isWordUnit(unit) {
                index = scanWord(at: index)
            } else if Self.operatorUnits.contains(unit) {
                var end = index
                while end < count, Self.operatorUnits.contains(units[end]) {
                    if units[end] == Char.minus, end + 1 < count, units[end + 1] == Char.minus,
                        end > index
                    {
                        break
                    }
                    end += 1
                }
                sink.add(.op, index, end)
                index = end
            } else if Self.punctuationUnits.contains(unit) {
                sink.add(.punctuation, index, index + 1)
                index += 1
            } else {
                index += 1
            }
        }
        return sink.tokens
    }

    private func endOfBlockComment(from start: Int) -> Int {
        var position = start + 2
        while position + 1 < units.count {
            if units[position] == Char.star, units[position + 1] == Char.slash {
                return position + 2
            }
            position += 1
        }
        return units.count
    }

    /// A doubled quote inside the string is an escaped quote.
    private func endOfSingleQuoted(from start: Int) -> Int {
        var position = start + 1
        while position < units.count {
            if units[position] == Char.singleQuote {
                if position + 1 < units.count, units[position + 1] == Char.singleQuote {
                    position += 2
                    continue
                }
                return position + 1
            }
            position += 1
        }
        return units.count
    }

    private func endOfNumber(from start: Int) -> Int {
        var position = start
        var seenDot = false
        while position < units.count {
            let unit = units[position]
            if Char.isDigit(unit) {
                position += 1
            } else if unit == Char.dot, !seenDot, position + 1 < units.count,
                Char.isDigit(units[position + 1])
            {
                seenDot = true
                position += 1
            } else {
                break
            }
        }
        // A digit run glued to letters (`2fa`) is an identifier, not a number.
        if position < units.count, Char.isWordUnit(units[position]) {
            while position < units.count, Char.isWordUnit(units[position]) { position += 1 }
            return start
        }
        return position
    }

    private mutating func scanWord(at start: Int) -> Int {
        var end = start
        while end < units.count, Char.isWordUnit(units[end]) { end += 1 }
        if end - start <= Self.longestKeyword, isKeyword(start, end) {
            sink.add(.keyword, start, end)
        }
        return end
    }

    private func isKeyword(_ start: Int, _ end: Int) -> Bool {
        var lowered = String.UnicodeScalarView()
        for unit in units[start..<end] {
            guard unit < 128, let scalar = Unicode.Scalar(unit) else { return false }
            lowered.append(unit >= 65 && unit <= 90 ? Unicode.Scalar(unit + 32)! : scalar)
        }
        return Self.keywords.contains(String(lowered))
    }
}

// MARK: - YAML

private struct YAMLLexer {
    private let units: [UInt16]
    private var sink = TokenSink()

    init(_ units: [UInt16]) { self.units = units }

    private static let literalKeywords: Set<String> = ["true", "false", "null", "~"]

    mutating func run() -> [SnippetToken] {
        let count = units.count
        var lineStart = 0
        /// Lines indented deeper than this belong to a block scalar and stay untokenised.
        var blockScalarParentIndent: Int?
        while lineStart <= count {
            var lineEnd = units.endOfLine(from: lineStart)
            let nextLine =
                lineEnd < count && units[lineEnd] == Char.carriageReturn
                    && lineEnd + 1 < count && units[lineEnd + 1] == Char.newline
                ? lineEnd + 2 : lineEnd + 1
            if lineEnd > lineStart, units[lineEnd - 1] == Char.carriageReturn { lineEnd -= 1 }
            scanLine(
                from: lineStart, to: lineEnd, blockScalarParentIndent: &blockScalarParentIndent)
            lineStart = nextLine
        }
        return sink.tokens
    }

    private mutating func scanLine(
        from start: Int, to end: Int, blockScalarParentIndent: inout Int?
    ) {
        var index = start
        while index < end, Char.isBlank(units[index]) { index += 1 }
        guard index < end else { return }
        let indent = index - start
        if let parent = blockScalarParentIndent {
            if indent > parent { return }
            blockScalarParentIndent = nil
        }
        if units[index] == Char.hash {
            sink.add(.comment, index, end)
            return
        }
        if isDocumentMarker(at: index, end: end) {
            sink.add(.punctuation, index, index + 3)
            index += 3
        }
        while index < end, units[index] == Char.minus,
            index + 1 == end || Char.isBlank(units[index + 1])
        {
            sink.add(.punctuation, index, index + 1)
            index += 1
            while index < end, Char.isBlank(units[index]) { index += 1 }
        }
        if let keyEnd = endOfKey(from: index, to: end) {
            sink.add(.key, index, keyEnd.key)
            index = keyEnd.afterColon
        }
        if scanValue(from: index, to: end) { blockScalarParentIndent = indent }
    }

    private func isDocumentMarker(at index: Int, end: Int) -> Bool {
        guard index + 3 <= end else { return false }
        let marker = units[index]
        guard marker == Char.minus || marker == Char.dot else { return false }
        guard units[index + 1] == marker, units[index + 2] == marker else { return false }
        return index + 3 == end || Char.isBlank(units[index + 3])
    }

    /// The end of the key and the index after its colon, when the line holds `key:` or `key: value`.
    private func endOfKey(from start: Int, to end: Int) -> (key: Int, afterColon: Int)? {
        guard start < end else { return nil }
        let first = units[start]
        if first == Char.doubleQuote || first == Char.singleQuote {
            let close = units.endOfQuote(
                from: start, limit: end, escapes: first == Char.doubleQuote)
            guard close < end || units[close - 1] == first, close - 1 > start else { return nil }
            var colon = close
            while colon < end, Char.isBlank(units[colon]) { colon += 1 }
            guard colon < end, units[colon] == Char.colon, isSeparator(after: colon, end: end)
            else {
                return nil
            }
            return (close, colon + 1)
        }
        if first == Char.openBracket || first == Char.openBrace || first == Char.hash { return nil }
        var position = start
        while position < end {
            let unit = units[position]
            if unit == Char.hash, position > start, Char.isBlank(units[position - 1]) { return nil }
            if unit == Char.colon, isSeparator(after: position, end: end) {
                var keyEnd = position
                while keyEnd > start, Char.isBlank(units[keyEnd - 1]) { keyEnd -= 1 }
                return keyEnd > start ? (keyEnd, position + 1) : nil
            }
            position += 1
        }
        return nil
    }

    private func isSeparator(after colon: Int, end: Int) -> Bool {
        colon + 1 == end || Char.isBlank(units[colon + 1])
    }

    /// Tokenises the rest of the line; true when it opens a block scalar (`|` or `>`).
    private mutating func scanValue(from start: Int, to end: Int) -> Bool {
        var index = start
        var opensBlockScalar = false
        while index < end {
            let unit = units[index]
            if Char.isBlank(unit) {
                index += 1
            } else if unit == Char.hash {
                sink.add(.comment, index, end)
                return opensBlockScalar
            } else if unit == Char.doubleQuote || unit == Char.singleQuote {
                let close = units.endOfQuote(
                    from: index, limit: end, escapes: unit == Char.doubleQuote)
                sink.add(.string, index, close)
                index = close
            } else {
                var scalarEnd = index
                var trimmedEnd = index
                while scalarEnd < end {
                    if units[scalarEnd] == Char.hash, scalarEnd > index,
                        Char.isBlank(units[scalarEnd - 1])
                    {
                        break
                    }
                    if !Char.isBlank(units[scalarEnd]) { trimmedEnd = scalarEnd + 1 }
                    scalarEnd += 1
                }
                classifyScalar(index, trimmedEnd)
                if isBlockScalarHeader(index, trimmedEnd) { opensBlockScalar = true }
                index = scalarEnd
            }
        }
        return opensBlockScalar
    }

    private mutating func classifyScalar(_ start: Int, _ end: Int) {
        if isNumber(start, end) {
            sink.add(.number, start, end)
        } else if end - start <= 5, isLiteralKeyword(start, end) {
            sink.add(.keyword, start, end)
        }
    }

    private func isBlockScalarHeader(_ start: Int, _ end: Int) -> Bool {
        guard units[start] == 124 || units[start] == Char.greaterThan else { return false }
        return units[(start + 1)..<end].allSatisfy {
            $0 == Char.minus || $0 == Char.plus || Char.isDigit($0)
        }
    }

    private func isLiteralKeyword(_ start: Int, _ end: Int) -> Bool {
        let text = String(decoding: units[start..<end], as: UTF16.self)
        return Self.literalKeywords.contains(text)
    }

    /// An optionally signed decimal with optional fraction and exponent spanning the whole range.
    private func isNumber(_ start: Int, _ end: Int) -> Bool {
        var position = start
        if units[position] == Char.minus || units[position] == Char.plus { position += 1 }
        let digitsStart = position
        while position < end, Char.isDigit(units[position]) { position += 1 }
        guard position > digitsStart else { return false }
        if position < end, units[position] == Char.dot {
            position += 1
            while position < end, Char.isDigit(units[position]) { position += 1 }
        }
        if position < end, units[position] == 101 || units[position] == 69 {
            position += 1
            if position < end, units[position] == Char.minus || units[position] == Char.plus {
                position += 1
            }
            let exponentStart = position
            while position < end, Char.isDigit(units[position]) { position += 1 }
            guard position > exponentStart else { return false }
        }
        return position == end
    }
}

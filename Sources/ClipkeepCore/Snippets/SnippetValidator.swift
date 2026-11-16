/// The result of a structural syntax check of a snippet.
public enum SnippetCheck: Sendable, Equatable {
    case valid
    /// The snippet is certainly broken. The hint is a short German sentence for the user; it
    /// names the construct at fault and never repeats the snippet beyond a short fragment.
    case invalid(hint: String)
    /// The checker was not confident either way, for example because the snippet uses a construct
    /// it does not model. Never reported as an error.
    case notChecked

    /// The line the explorer and the creation sheet show, or nil when there is nothing to say.
    public var statusText: String? {
        switch self {
        case .valid: "✓ Syntax gültig"
        case .invalid(let hint): "✗ Syntax ungültig: \(hint)"
        case .notChecked: nil
        }
    }
}

/// Checks the structure of a snippet without ever running it: quotes, brackets, dangling operators
/// and a few per-language rules. Each language has a hand-written single-pass scanner that knows a
/// deliberately small subset of the language. Anything outside that subset makes the whole check
/// `notChecked`, because a false "invalid" on working code is worse than no verdict.
public enum SnippetValidator {
    /// Snippets are capped at 32 KB, so this leaves a wide margin. Longer text is not checked, so
    /// the check never costs the main thread noticeable time.
    public static let maximumUTF8Length = 256 * 1024

    public static func check(_ text: String, language: SnippetLanguage) -> SnippetCheck {
        guard text.utf8.count <= maximumUTF8Length else { return .notChecked }
        return evaluate(text, language: language)
    }

    /// The checkers without the length limit. Every scanner advances by at least one byte per step
    /// and tracks nesting in arrays, not recursion, so any input terminates in linear time.
    static func evaluate(_ text: String, language: SnippetLanguage) -> SnippetCheck {
        let bytes = Array(text.utf8)
        guard bytes.contains(where: { !ASCII.isWhitespace($0) }) else { return .notChecked }
        do {
            switch language {
            case .shell:
                var checker = ShellSyntaxChecker(bytes)
                return try checker.run()
            case .sql:
                var checker = SQLSyntaxChecker(bytes)
                return try checker.run()
            case .yaml:
                var checker = YAMLSyntaxChecker(bytes)
                return try checker.run()
            }
        } catch {
            switch error {
            case .invalid(let hint): return .invalid(hint: hint)
            case .notChecked: return .notChecked
            }
        }
    }
}

/// How a checker stops early: with a certain error or because it is out of its depth.
enum SyntaxProblem: Error {
    case invalid(String)
    case notChecked
}

/// Byte constants for the UTF-8 scanners. Every structural character is ASCII, so multi-byte
/// characters are plain content and never split a construct.
enum ASCII {
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let doubleQuote = UInt8(ascii: "\"")
    static let singleQuote = UInt8(ascii: "'")
    static let backtick = UInt8(ascii: "`")
    static let backslash = UInt8(ascii: "\\")
    static let dollar = UInt8(ascii: "$")
    static let hash = UInt8(ascii: "#")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let pipe = UInt8(ascii: "|")
    static let ampersand = UInt8(ascii: "&")
    static let semicolon = UInt8(ascii: ";")
    static let less = UInt8(ascii: "<")
    static let greater = UInt8(ascii: ">")
    static let equals = UInt8(ascii: "=")
    static let tilde = UInt8(ascii: "~")
    static let colon = UInt8(ascii: ":")
    static let comma = UInt8(ascii: ",")
    static let dash = UInt8(ascii: "-")
    static let slash = UInt8(ascii: "/")
    static let star = UInt8(ascii: "*")
    static let question = UInt8(ascii: "?")
    static let exclamation = UInt8(ascii: "!")
    static let at = UInt8(ascii: "@")
    static let plus = UInt8(ascii: "+")
    static let percent = UInt8(ascii: "%")
    static let period = UInt8(ascii: ".")
    static let underscore = UInt8(ascii: "_")

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == lineFeed || byte == carriageReturn
    }

    static func isBlank(_ byte: UInt8) -> Bool { byte == space || byte == tab }

    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    /// Letters, digits, underscore and every byte of a multi-byte UTF-8 character.
    static func isIdentifier(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte == underscore || byte >= 0x80
    }

    /// The ASCII upper-case form of `bytes`, for keyword comparison.
    static func uppercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }, as: UTF8.self)
    }
}

extension Array where Element == UInt8 {
    /// The byte at `index`, or nil past either end, so look-ahead never traps.
    func byte(at index: Int) -> UInt8? {
        indices.contains(index) ? self[index] : nil
    }
}

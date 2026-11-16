import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetHighlighterTests {
    private func kinds(_ text: String, _ language: SnippetLanguage) -> [(String, SnippetTokenKind)]
    {
        let utf16 = text as NSString
        return SnippetHighlighter.tokens(in: text, language: language).map {
            (utf16.substring(with: $0.range), $0.kind)
        }
    }

    private func kind(of piece: String, in tokens: [(String, SnippetTokenKind)])
        -> SnippetTokenKind?
    {
        tokens.first { $0.0 == piece }?.1
    }

    @Test func shellFlagsVariablesStringsAndComments() {
        let tokens = kinds(#"grep -rn "foo" $HOME # note"#, .shell)
        #expect(kind(of: "grep", in: tokens) == .keyword)
        #expect(kind(of: "-rn", in: tokens) == .variable)
        #expect(kind(of: #""foo""#, in: tokens) == .string)
        #expect(kind(of: "$HOME", in: tokens) == .variable)
        #expect(kind(of: "# note", in: tokens) == .comment)
    }

    @Test func shellPipesAreOperators() {
        let tokens = kinds("cat a | grep b && ls > out", .shell)
        #expect(kind(of: "|", in: tokens) == .op)
        #expect(kind(of: "&&", in: tokens) == .op)
        #expect(kind(of: ">", in: tokens) == .op)
        #expect(kind(of: "grep", in: tokens) == .keyword)
        #expect(kind(of: "ls", in: tokens) == .keyword)
        #expect(kind(of: "b", in: tokens) == nil)
    }

    @Test func shellHashInsideAWordIsNotAComment() {
        let tokens = kinds("echo a#b", .shell)
        #expect(tokens.contains { $0.1 == .comment } == false)
    }

    @Test func sqlKeywordsAreCaseInsensitive() {
        let tokens = kinds("select a FROM t Where x = 'x' AND y > 42 -- c", .sql)
        #expect(kind(of: "select", in: tokens) == .keyword)
        #expect(kind(of: "FROM", in: tokens) == .keyword)
        #expect(kind(of: "Where", in: tokens) == .keyword)
        #expect(kind(of: "'x'", in: tokens) == .string)
        #expect(kind(of: "42", in: tokens) == .number)
        #expect(kind(of: "-- c", in: tokens) == .comment)
        #expect(kind(of: "t", in: tokens) == nil)
    }

    @Test func sqlDigitsInsideIdentifiersAreNotNumbers() {
        let tokens = kinds("select t1.c2 from t1", .sql)
        #expect(tokens.contains { $0.1 == .number } == false)
    }

    @Test func yamlKeysValuesAndComments() {
        let tokens = kinds("name: web # c", .yaml)
        #expect(kind(of: "name", in: tokens) == .key)
        #expect(kind(of: "web", in: tokens) == nil)
        #expect(kind(of: "# c", in: tokens) == .comment)

        let list = kinds("- item", .yaml)
        #expect(kind(of: "-", in: list) == .punctuation)
        #expect(kind(of: "item", in: list) == nil)

        let number = kinds("spec:\n  replicas: 3", .yaml)
        #expect(kind(of: "replicas", in: number) == .key)
        #expect(kind(of: "3", in: number) == .number)
    }

    @Test func yamlUrlIsNotAKey() {
        let tokens = kinds("url: http://example.com/a", .yaml)
        #expect(tokens.filter { $0.1 == .key }.map(\.0) == ["url"])
    }

    @Test(arguments: [
        (SnippetLanguage.shell, "echo \"abc"), (.sql, "select 'abc"), (.yaml, "k: \"abc"),
    ])
    func unterminatedStringRunsToTheEndWithoutCrashing(language: SnippetLanguage, text: String) {
        let tokens = SnippetHighlighter.tokens(in: text, language: language)
        let string = tokens.first { $0.kind == .string }
        #expect(string != nil)
        #expect(string.map { NSMaxRange($0.range) } == (text as NSString).length)
    }

    @Test(arguments: SnippetLanguage.allCases)
    func rangesAreOrderedNonOverlappingAndInBounds(language: SnippetLanguage) {
        let text =
            "echo \"héllo 😀\" | grep 'ü' # 😀\nselect 'ä😀' from t -- ö\nkey: \"😀\" # ü\n- 7 $X -f"
        let length = (text as NSString).length
        var previousEnd = 0
        for token in SnippetHighlighter.tokens(in: text, language: language) {
            #expect(token.range.location >= previousEnd)
            #expect(token.range.length > 0)
            #expect(NSMaxRange(token.range) <= length)
            previousEnd = NSMaxRange(token.range)
        }
    }

    /// Checks the token invariants and returns the tokens.
    @discardableResult
    private func checkedTokens(_ text: String, _ language: SnippetLanguage, limit: Double = 2.0)
        -> [SnippetToken]
    {
        let start = Date()
        let tokens = SnippetHighlighter.scan(text, language: language)
        #expect(Date().timeIntervalSince(start) < PerformanceBudget.limit(limit))
        let string = text as NSString
        var previousEnd = 0
        for token in tokens {
            #expect(token.range.length > 0)
            #expect(token.range.location >= previousEnd)
            #expect(NSMaxRange(token.range) <= string.length)
            previousEnd = max(previousEnd, NSMaxRange(token.range))
            if NSMaxRange(token.range) <= string.length {
                #expect(!string.substring(with: token.range).contains("\u{FFFD}"))
            }
        }
        return tokens
    }

    @Test(arguments: SnippetLanguage.allCases)
    func digitGluedWordsTerminateAndAreNotNumbers(language: SnippetLanguage) {
        let text = "select 2fa, 0xFF, 1_000, 10px, 1e3, 1é from t"
        let tokens = checkedTokens(text, language)
        let string = text as NSString
        let numbers = tokens.filter { $0.kind == .number }.map { string.substring(with: $0.range) }
        for glued in ["2fa", "0xFF", "1_000", "10px", "1e3", "1é"] {
            #expect(!numbers.contains { $0.contains(glued) || glued.contains($0) })
        }
    }

    @Test func largeInputIsBounded() {
        let pieces: [(SnippetLanguage, String)] = [
            (.shell, "echo \"a\" | grep -v b && "), (.sql, "select 1 from t where a = 'x' and "),
            (.yaml, "key: value "),
        ]
        for (language, piece) in pieces {
            let text = String(repeating: piece, count: 1_048_576 / piece.utf8.count)
            #expect(!checkedTokens(text, language).isEmpty)
        }
    }

    @Test(arguments: SnippetLanguage.allCases)
    func adversarialLargeInputsTerminate(language: SnippetLanguage) {
        let megabyte = 1_048_576
        let inputs = [
            "\"" + String(repeating: "a", count: megabyte),
            "'" + String(repeating: "a", count: megabyte),
            String(repeating: "$", count: megabyte),
            String(repeating: "-", count: megabyte),
            String(repeating: "$-", count: megabyte / 2),
            String(repeating: "😀é", count: megabyte / 6),
            String(repeating: "a: 1\r\n", count: megabyte / 7),
            String(repeating: "select 2fa 1é 0xFF\r\n", count: megabyte / 22),
            String(repeating: "\\", count: megabyte),
            String(repeating: "1", count: megabyte) + "x",
        ]
        for text in inputs { checkedTokens(text, language, limit: 3.0) }
    }

    @Test func textOverTheHighlightLimitGetsNoTokens() {
        let text = String(repeating: "a ", count: SnippetHighlighter.maximumUTF16Length)
        #expect(SnippetHighlighter.tokens(in: text, language: .shell).isEmpty)
        #expect(!SnippetHighlighter.tokens(in: "ls -la", language: .shell).isEmpty)
    }

    @Test(arguments: SnippetLanguage.allCases)
    func emptyTextHasNoTokens(language: SnippetLanguage) {
        #expect(SnippetHighlighter.tokens(in: "", language: language).isEmpty)
    }
}

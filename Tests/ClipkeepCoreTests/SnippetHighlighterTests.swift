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

    @Test func largeInputIsBounded() {
        let pieces: [(SnippetLanguage, String)] = [
            (.shell, "echo \"a\" | grep -v b && "), (.sql, "select 1 from t where a = 'x' and "),
            (.yaml, "key: value "),
        ]
        for (language, piece) in pieces {
            let text = String(repeating: piece, count: 1_048_576 / piece.utf8.count)
            let start = Date()
            _ = SnippetHighlighter.tokens(in: text, language: language)
            #expect(Date().timeIntervalSince(start) < PerformanceBudget.limit(1.0))
        }
    }

    @Test(arguments: SnippetLanguage.allCases)
    func emptyTextHasNoTokens(language: SnippetLanguage) {
        #expect(SnippetHighlighter.tokens(in: "", language: language).isEmpty)
    }
}

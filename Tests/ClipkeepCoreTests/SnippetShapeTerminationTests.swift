import Foundation
import Testing

@testable import ClipkeepCore

/// The shape runs inside the database write of every snippet add and over every stored snippet
/// in migration 13, so a scanner that stops advancing hangs the app. These inputs must all
/// finish quickly, and the shape must keep its invariants on any of them.
@Suite struct SnippetShapeTerminationTests {
    private static let punctuation = Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// The shape is deterministic and keeps the line count of the trimmed input.
    private func checkedShape(_ text: String, _ language: SnippetLanguage) -> String {
        let shape = SnippetShape.of(text, language: language)
        #expect(shape == SnippetShape.of(text, language: language))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedLines = trimmed.split(
            omittingEmptySubsequences: false, whereSeparator: \.isNewline
        ).count
        let shapeLines = shape.split(
            omittingEmptySubsequences: false, whereSeparator: \.isNewline
        ).count
        #expect(shapeLines == expectedLines, "\(text.debugDescription)")
        return shape
    }

    @Test(arguments: SnippetLanguage.allCases)
    func everyPunctuationPairTerminates(language: SnippetLanguage) {
        for first in Self.punctuation {
            for second in Self.punctuation {
                let pair = "\(first)\(second)"
                _ = checkedShape(pair, language)
                _ = checkedShape("cmd a\(pair)b \(pair) c", language)
            }
        }
    }

    @Test(arguments: SnippetLanguage.allCases)
    func everyPunctuationTripleTerminates(language: SnippetLanguage) {
        for first in Self.punctuation {
            for second in Self.punctuation {
                for third in Self.punctuation {
                    _ = checkedShape("x \(first)\(second)\(third) y", language)
                }
            }
        }
    }

    @Test(arguments: [
        "diff <(ls a) <(ls b)", "tee >(gzip)", "source <(kubectl completion zsh)",
        "cat <(", "cat >(", "a<(b", "x >(y >(z", "echo $(", "echo $( ls ( )", "2>(x)",
        "cmd <(<(<(", "echo `a", "echo \"a $(b\"", "x\\", "<", ">", "&>", "2>&", "<<<",
    ])
    func processSubstitutionAndOpenGroupsTerminate(text: String) {
        _ = checkedShape(text, .shell)
    }

    @Test func processSubstitutionIsOneLiteralWord() {
        #expect(
            SnippetShape.of("diff <(ls a) <(ls b)", language: .shell) == "diff <(ls a) <(ls b)")
        #expect(SnippetShape.of("tee >(gzip)", language: .shell) == "tee >(gzip)")
    }

    @Test func commandSubstitutionStaysOneWord() {
        // `$( … )` used to split into words after the `$`.
        #expect(SnippetShape.of("echo $(ls -la)", language: .shell) == "echo $(ls -la)")
    }

    @Test(arguments: SnippetLanguage.allCases)
    func adversarialMegabyteInputsTerminate(language: SnippetLanguage) {
        let megabyte = 1_048_576
        let inputs = [
            "\"" + String(repeating: "a", count: megabyte),
            "'" + String(repeating: "a b", count: megabyte / 3),
            "`" + String(repeating: "a", count: megabyte),
            String(repeating: "$(", count: megabyte / 2),
            String(repeating: "(", count: megabyte), String(repeating: ")", count: megabyte),
            String(repeating: "<(", count: megabyte / 2),
            String(repeating: ">(", count: megabyte / 2),
            String(repeating: "<( ", count: megabyte / 3),
            String(repeating: "a <(b) ", count: megabyte / 7),
            String(repeating: "x\r\n", count: megabyte / 3),
            String(repeating: "😀 é ", count: megabyte / 8),
            String(repeating: "& ", count: megabyte / 2),
            String(repeating: "!a ", count: megabyte / 3),
            String(repeating: "- ", count: megabyte / 2),
            String(repeating: "[{", count: megabyte / 2),
            String(repeating: "2>&1 ", count: megabyte / 5),
            String(repeating: "> x ", count: megabyte / 4),
            String(repeating: "<<", count: megabyte / 2),
            String(repeating: "\\", count: megabyte),
            String(repeating: "a: ", count: megabyte / 3),
            String(repeating: "'", count: megabyte),
            String(repeating: "--", count: megabyte / 2),
            String(repeating: "sudo ", count: megabyte / 5),
            String(repeating: "ssh -p ", count: megabyte / 7),
        ]
        // One megabyte takes about three seconds on a shared CI runner; a hang or a quadratic scan
        // takes minutes, so the budget leaves room for runner noise and still catches both.
        for text in inputs {
            let start = Date()
            _ = checkedShape(text, language)
            #expect(
                Date().timeIntervalSince(start) < PerformanceBudget.limit(10.0),
                "\(text.prefix(8).debugDescription)")
        }
    }

    @Test func crlfLinesKeepTheirCount() {
        #expect(SnippetShape.of("cd /a\r\nls /b", language: .shell) == "cd \u{1}path\nls \u{1}path")
        #expect(
            SnippetShape.hash(of: "a: 1\r\nb: 2", language: .yaml)
                == SnippetShape.hash(of: "a: 1\nb: 2", language: .yaml))
    }
}

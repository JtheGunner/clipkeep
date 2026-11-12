import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetFilterTests {
    private static let composeFile =
        "services:\n  web:\n    image: nginx:1.27\n    ports:\n      - \"80:80\""

    @Test(arguments: [
        ("docker run --rm -v \"$PWD\":/app -w /app node:20 npm test", SnippetLanguage.shell),
        (
            "kubectl get pods -n prod | grep Crash\nkubectl delete pod web-1 -n prod",
            .shell
        ),
        ("git status\ngit pull --rebase", .shell),
        ("./scripts/build.sh --release\n./scripts/test.sh --filter Core", .shell),
        ("$ brew install swift-format", .shell),
        (
            "SELECT u.id, count(*) FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.id HAVING count(*) > 5;",
            .sql
        ),
        ("-- latest orders\nselect * from orders where id > 10", .sql),
        ("INSERT INTO users (id, name) VALUES (1, 'Ada');", .sql),
        ("UPDATE users SET name = 'Ada' WHERE id = 1", .sql),
        ("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);", .sql),
        ("WITH recent AS (SELECT * FROM orders) SELECT count(*) FROM recent", .sql),
        (composeFile, .yaml),
        (
            "- hosts: all\n  tasks:\n    - name: ping\n      ping:\n    - name: upgrade\n      apt: upgrade=dist",
            .yaml
        ),
        ("data:\n  script: |\n    echo one\n    echo two\n  mode: fast", .yaml),
    ])
    func acceptsSnippets(text: String, expected: SnippetLanguage) {
        #expect(SnippetFilter.evaluate(text) == expected)
    }

    @Test(arguments: [
        "cd src",
        "ls",
        "git status",
        "let count = 5",
        "name: Alice",
        "SELECT",
        "FOO=bar\nBAZ=qux",
        "https://example.com/a/b",
        "{\"a\": 1}",
        """
        Exception in thread "main" java.lang.IllegalStateException: boom
            at com.example.App.run(App.java:42)
            at com.example.App.main(App.java:10)
        """,
        "Please run the query again tomorrow after lunch",
        "",
        "   \n  ",
        "cd src\nls",
        "make sure you go home early",
        "git is a nice tool.",
        "Select the best option from the list.",
        "a: 1\nb: 2\nc: 3",
        "- milk\n- eggs\n  - organic\n- bread",
        "From: Ada\nTo: Grace\nSubject: Lunch",
        "/usr/local/etc/some/very/long/path/file.conf",
        "42",
    ])
    func rejectsNonSnippets(text: String) {
        #expect(SnippetFilter.evaluate(text) == nil)
    }

    @Test func crlfDoesNotChangeTheVerdict() {
        let windows = Self.composeFile
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0 + "   " }
            .joined(separator: "\r\n")

        #expect(SnippetFilter.evaluate(windows) == .yaml)
        #expect(SnippetFilter.evaluate(windows + "\r\n") == .yaml)
    }

    @Test func trailingWhitespaceDoesNotChangeTheShellVerdict() {
        let text = "kubectl get pods -n prod | grep Crash  \r\nkubectl delete pod web-1 -n prod \t"

        #expect(SnippetFilter.evaluate(text) == .shell)
    }

    @Test func onlyTheStartOfALongYAMLFileIsInspected() {
        let entries = (0..<200).map { "  key\($0): value\($0)" }.joined(separator: "\n")
        let text = "settings:\n" + entries

        #expect(SnippetFilter.evaluate(text) == .yaml)
    }

    @Test func hugeInputReturnsInBoundedTime() {
        let text = String(repeating: "echo hello | cat\n", count: 2 * 1024 * 1024 / 17)
        let started = Date()

        _ = SnippetFilter.evaluate(text)

        #expect(Date().timeIntervalSince(started) < PerformanceBudget.limit(1.0))
    }

    @Test func manyShortLinesReturnInBoundedTime() {
        let text = String(repeating: "a: b\n", count: 50_000)
        let started = Date()

        _ = SnippetFilter.evaluate(text)

        #expect(Date().timeIntervalSince(started) < PerformanceBudget.limit(1.0))
    }

    @Test func hostileInputsBelowTheSizeLimitStayFast() {
        let inputs = [
            "SELECT " + String(repeating: "a ", count: 15_000),
            "INSERT INTO t " + String(repeating: "x ", count: 15_000),
            "WITH x (" + String(repeating: "a,", count: 15_000),
            String(repeating: "  key: value\n", count: 2_400),
            "git " + String(repeating: "-", count: 30_000),
            "FOO=" + String(repeating: "a", count: 30_000) + " ls",
        ]
        let started = Date()

        for input in inputs { _ = SnippetFilter.evaluate(input) }

        #expect(Date().timeIntervalSince(started) < PerformanceBudget.limit(0.5))
    }

    /// A shell snippet padded with a trailing comment line to exactly `bytes` UTF-8 bytes.
    private static func paddedShellSnippet(bytes: Int) -> String {
        let head = "kubectl get pods -n prod | grep Crash\n"
        return head + String(repeating: "#", count: bytes - head.utf8.count)
    }

    @Test func textOfExactlyTheSizeLimitIsEvaluated() {
        let text = Self.paddedShellSnippet(bytes: SnippetFilter.Threshold.maximumBytes)

        #expect(text.utf8.count == 32 * 1024)
        #expect(SnippetFilter.evaluate(text) == .shell)
    }

    @Test func textOneByteOverTheSizeLimitIsRejected() {
        let text = Self.paddedShellSnippet(bytes: SnippetFilter.Threshold.maximumBytes + 1)

        #expect(SnippetFilter.evaluate(text) == nil)
    }

    @Test func thousandsOfLinesBelowTheSizeLimitReturnQuickly() {
        let text = String(repeating: "ls -la x\n", count: 3_300)
        let started = Date()

        _ = SnippetFilter.evaluate(text)

        #expect(text.utf8.count < SnippetFilter.Threshold.maximumBytes)
        #expect(Date().timeIntervalSince(started) < PerformanceBudget.limit(0.1))
    }

    @Test func evaluationIsDeterministic() {
        let text = "kubectl get pods -n prod | grep Crash"

        #expect(SnippetFilter.evaluate(text) == SnippetFilter.evaluate(text))
    }
}

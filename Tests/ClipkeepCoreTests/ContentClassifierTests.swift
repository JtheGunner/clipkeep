import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct ContentClassifierTests {
    @Test(arguments: [
        ("https://example.com/docs?a=1", ContentKind.url),
        ("www.example.com", .url),
        ("mailto:jeff@example.com", .url),
        ("jeff@example.com", .email),
        ("/Users/jeffry/Projects/clipkeep", .path),
        ("~/Library/Application Support/Clipkeep", .path),
        ("./scripts/test.sh", .path),
        ("C:\\Users\\jeff\\file.txt", .path),
        ("42", .number),
        ("-3.14", .number),
        ("1'234'567.50", .number),
        ("{\"name\": \"clipkeep\", \"tags\": [1, 2]}", .json),
        ("[1, 2, 3]", .json),
        ("git status", .command),
        ("$ docker compose up -d", .command),
        ("php artisan migrate --force", .command),
        ("Hello world, this is a normal sentence.", .text),
        ("", .text),
        ("   \n  ", .text),
    ])
    func classifiesSingleItems(sample: String, expected: ContentKind) {
        #expect(ContentClassifier.classify(sample) == expected)
    }

    @Test func recognizesStackTraces() {
        let java = """
            Exception in thread "main" java.lang.NullPointerException
                at com.example.App.run(App.java:42)
                at com.example.App.main(App.java:10)
            """
        let python = """
            Traceback (most recent call last):
              File "app.py", line 3, in <module>
                run()
            """
        #expect(ContentClassifier.classify(java) == .stacktrace)
        #expect(ContentClassifier.classify(python) == .stacktrace)
    }

    @Test func recognizesCode() {
        let swift = """
            func greet(name: String) -> String {
                return "Hello, \\(name)"
            }
            """
        let php = """
            <?php
            namespace App;
            class User { public function name() { return $this->name; } }
            """
        let oneLiner = "const total = items.map((item) => item.price).reduce((a, b) => a + b);"
        #expect(ContentClassifier.classify(swift) == .code)
        #expect(ContentClassifier.classify(php) == .code)
        #expect(ContentClassifier.classify(oneLiner) == .code)
    }

    @Test func proseIsNotMistakenForCodeOrCommands() {
        #expect(ContentClassifier.classify("git is a version control tool.") == .text)
        #expect(
            ContentClassifier.classify("Let's meet at the class reunion.\nBring a friend.") == .text
        )
        #expect(ContentClassifier.classify("See https://example.com for details") == .text)
        #expect(ContentClassifier.classify("a/b") == .text)
        #expect(ContentClassifier.classify("/") == .text)
        #expect(ContentClassifier.classify("{not json}") == .text)
    }

    @Test func multilineURLListIsNotASingleURL() {
        #expect(ContentClassifier.classify("https://a.example\nhttps://b.example") == .text)
    }

    @Test func largeTextIsClassifiedQuickly() {
        let text = String(repeating: "lorem ipsum dolor sit amet\n", count: 40_000)
        let started = Date()

        _ = ContentClassifier.classify(text)

        #expect(Date().timeIntervalSince(started) < 1)
    }
}

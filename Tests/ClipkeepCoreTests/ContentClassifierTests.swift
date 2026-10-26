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

        #expect(Date().timeIntervalSince(started) < PerformanceBudget.limit(0.1))
    }

    @Test func longLinesDoNotCauseQuadraticBacktracking() {
        let started = Date()

        for prefix in ["at ", "  File \"", "#1 0x"] {
            _ = ContentClassifier.classify(prefix + String(repeating: "a", count: 30_000))
            _ = ContentClassifier.classify(
                "x\n" + prefix + String(repeating: "a b", count: 10_000))
        }

        #expect(Date().timeIntervalSince(started) < PerformanceBudget.limit(0.5))
    }

    @Test func oversizedPastesAreTreatedAsText() {
        let json = "[" + String(repeating: "1,", count: 600_000) + "1]"

        #expect(ContentClassifier.classify(json) == .text)
    }

    @Test func aTraceBeyondTheSampleStillCountsByItsStart() {
        let frames = String(repeating: "    at com.example.App.run(App.java:42)\n", count: 2_000)

        #expect(
            ContentClassifier.classify("Exception in thread \"main\" X\n" + frames) == .stacktrace)
    }
}

private func threadCPUSeconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
}

@Suite struct ContentClassifierReviewTests {
    @Test func germanAndMixedLanguageSamplesLandInTheRightKind() {
        #expect(ContentClassifier.classify("Bitte die Rechnung bis Freitag überweisen.") == .text)
        #expect(
            ContentClassifier.classify(
                "Einkaufsliste:\n- Milch (2 Liter)\n- Brot (Vollkorn)\n- Käse (Gruyère)")
                == .text)
        #expect(
            ContentClassifier.classify("Meeting notes (draft)\nAgenda (v2)\nOutcome (tbd)") == .text
        )
        #expect(
            ContentClassifier.classify("Das Ticket CLIPK-12 ist erledigt, please review.") == .text)
        #expect(ContentClassifier.classify("1'234.50") == .number)
        #expect(ContentClassifier.classify("hans.müller@beispiel.ch") == .email)
        #expect(ContentClassifier.classify("~/Dokumente/Büro/Rechnung März.pdf") == .path)
        #expect(
            ContentClassifier.classify("git commit -m \"Fehler beim Speichern behoben\"")
                == .command)
    }

    @Test func proseStartingWithACommandWordIsText() {
        for sentence in [
            "go to the store and buy milk", "find out what happened", "make sure it works",
            "make the call tomorrow, ok?", "cat is cute", "go ahead", "ls of files attached",
            "echo of the past",
        ] {
            #expect(ContentClassifier.classify(sentence) == .text, "\(sentence)")
        }
    }

    @Test func realCommandsAreRecognizedIncludingPrefixesAndScripts() {
        for command in [
            "FOO=bar npm run build", "LANG=C sort file.txt | uniq -c", "user@host:~$ ls -la",
            "apt install jq", "make", "cd ~/Projects", "find . -name '*.swift'", "go test ./...",
            "echo $PATH", "cat file.txt | grep error", "ls -la /tmp",
            "#!/bin/bash\nset -e\nfor f in *.txt; do echo \"$f\"; done",
        ] {
            #expect(ContentClassifier.classify(command) == .command, "\(command)")
        }
    }

    @Test func agendaNotesAreNotStackTraces() {
        #expect(ContentClassifier.classify("Agenda\nat 10:00 standup\nat 14:00 review") == .text)
        #expect(
            ContentClassifier.classify("at the moment (we think: maybe)\nat home (now: yes)")
                == .text)
    }

    @Test func realStackFramesAreRecognized() {
        let node =
            "Error: boom\n    at Object.<anonymous> (/app/index.js:3:9)\n    at Module._compile (node:internal/modules/cjs/loader:1:1)"
        let nodeBare = "Error\n    at /app/server.js:10:5\n    at /app/server.js:20:7"

        #expect(ContentClassifier.classify(node) == .stacktrace)
        #expect(ContentClassifier.classify(nodeBare) == .stacktrace)
    }

    @Test func versionsAndAddressesAreNotNumbers() {
        for sample in ["127.0.0.1", "1.2.3", "+41 79 123 45 67", "1,2,3", "10.0.0.5:8080"] {
            #expect(ContentClassifier.classify(sample) != .number, "\(sample)")
        }
        for sample in ["1234", "1,234,567.50", "1'234'567", "-0.5", "3,14"] {
            #expect(ContentClassifier.classify(sample) == .number, "\(sample)")
        }
    }

    @Test func eachItemIsClassifiedWithinFiveMilliseconds() {
        let samples = [
            String(repeating: "Lorem ipsum dolor sit amet, consectetur.\n", count: 800),
            String(repeating: "func f() { return 1; }\n", count: 800),
            String(repeating: "    at com.example.App.run(App.java:42)\n", count: 800),
        ]
        // The first call compiles the static regexes, so warm up. CPU time of this thread is used
        // because other tests run in parallel and wall-clock time would include their load.
        for sample in samples { _ = ContentClassifier.classify(sample) }

        let perItem =
            (0..<3).map { _ -> Double in
                let started = threadCPUSeconds()
                for sample in samples { _ = ContentClassifier.classify(sample) }
                return (threadCPUSeconds() - started) / Double(samples.count)
            }.min() ?? .infinity
        #expect(
            !PerformanceBudget.isEnforced || perItem < 0.005,
            "took \(perItem * 1000) ms per item")
    }
}

@Suite struct ClassifierAdversarialInputTests {
    @Test func hostileLinesStayFast() {
        let inputs = [
            String(repeating: "@", count: 30_000),
            "a@" + String(repeating: ":", count: 30_000),
            String(repeating: "a@b:", count: 8_000),
            "import " + String(repeating: " ", count: 30_000) + "x",
            "import " + String(repeating: "a ", count: 15_000),
            String(repeating: "return ", count: 5_000),
            "FOO=" + String(repeating: "a=b ", count: 8_000),
            String(repeating: "$ ", count: 15_000),
        ]
        let started = Date()

        for input in inputs {
            _ = ContentClassifier.classify(input)
            _ = ContentClassifier.classify("x\n" + input + "\ny")
        }

        #expect(Date().timeIntervalSince(started) < PerformanceBudget.limit(1))
    }
}

import ClipkeepCore
import Foundation

// clipkeep-eval: measures search and session quality on a corpus and a gold set.
//
//   clipkeep-eval                              synthetic corpus, compared with eval/baseline.json
//   clipkeep-eval --write-baseline             store the current values as the baseline
//   clipkeep-eval --text notes.txt --gold g.json   an imported text file and your own gold set
//   clipkeep-eval --snippets [--report FILE]   judge the snippet filter on your real history
//   options: --corpus FILE  --gold FILE  --baseline FILE  --report FILE
//            --split automatic|separators|blank-lines|every-line   how --text is cut into entries

let splitModes: [String: SplitMode] = [
    "automatic": .automatic, "separators": .separatorLines, "blank-lines": .blankLines,
    "every-line": .everyLine,
]

struct Options {
    var corpus = "eval/synthetic-corpus.json"
    var gold = "eval/synthetic-gold.json"
    var baseline: String?
    var usesText = false
    var text: String?
    var report: String?
    var splitMode = SplitMode.automatic
    var writeBaseline = false
    var snippets = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        func value() -> String {
            guard let next = iterator.next() else { fail("Missing value for \(argument)") }
            return next
        }
        switch argument {
        case "--corpus": options.corpus = value()
        case "--gold": options.gold = value()
        case "--baseline": options.baseline = value()
        case "--text":
            options.text = value()
            options.usesText = true
        case "--split":
            let name = value()
            guard let mode = splitModes[name] else {
                let known = splitModes.keys.sorted().joined(separator: ", ")
                fail("Unknown split mode \(name); use \(known)")
            }
            options.splitMode = mode
        case "--report": options.report = value()
        case "--write-baseline": options.writeBaseline = true
        case "--snippets": options.snippets = true
        default: fail("Unknown option \(argument)")
        }
    }
    // Your own data has no baseline unless one is named, whatever the order of the options.
    if options.baseline == nil, !options.usesText { options.baseline = "eval/baseline.json" }
    return options
}

func load<T: Decodable>(_ type: T.Type, _ path: String) -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        fail("Cannot read \(path): \(error)")
    }
}

/// Runs the snippet filter over the real history through a read-only connection: nothing is
/// created, migrated or written. The report holds copied content, so it is written owner-only
/// and refused inside the repository.
func runSnippetEvaluation(reportPath: String?) -> Never {
    let output = EvaluationOutput.decide(
        isTerminal: isatty(STDOUT_FILENO) != 0, reportPath: reportPath)
    if output == .refusedNonInteractive {
        fail("--snippets prints private clipboard text; give --report FILE or run it in a terminal")
    }
    let root = EvaluationReportWriter.repositoryRoot(
        startingAt: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let report: SnippetEvaluationReport
    do {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: false)
        let path = support.appendingPathComponent("Clipkeep/clipkeep.db").path
        guard FileManager.default.fileExists(atPath: path) else {
            fail("No Clipkeep database at \(path)")
        }
        let database = try Database(
            path: path, key: try KeychainDatabaseKeyStore().loadOrCreateKey(), readOnly: true)
        report = try SnippetEvaluation.run(database: database)
    } catch {
        fail("Snippet evaluation failed: \(error)")
    }
    let text = report.rendered()
    switch output {
    case .reportFile(let path):
        do {
            try EvaluationReportWriter.write(text, to: path, repositoryRoot: root)
        } catch {
            fail("Cannot write the report to \(path): \(error)")
        }
        print(
            "Examined \(report.examined), accepted \(report.accepted.count), "
                + "rejected but code-like \(report.rejectedCodeLike.count); report in \(path)")
    case .terminal:
        FileHandle.standardError.write(
            Data(
                "Warning: the output contains private clipboard text and may stay in scrollback or logs.\n"
                    .utf8))
        print(text, terminator: "")
    case .refusedNonInteractive:
        break
    }
    exit(0)
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
if options.snippets { runSnippetEvaluation(reportPath: options.report) }
let gold = load(GoldSet.self, options.gold)
let metrics: EvalMetrics
let title: String
do {
    if let textPath = options.text {
        let text = try TextImporter.read(URL(fileURLWithPath: textPath))
        metrics = try EvalRunner.run(importing: text, gold: gold, mode: options.splitMode)
        title = "Evaluation of \(URL(fileURLWithPath: textPath).lastPathComponent)"
    } else {
        metrics = try EvalRunner.run(corpus: load(EvalCorpus.self, options.corpus), gold: gold)
        title = "Evaluation of the synthetic corpus"
    }
} catch {
    fail("Evaluation failed: \(error)")
}

var regressions: [EvalRegression] = []
if options.writeBaseline {
    guard let path = options.baseline else { fail("--write-baseline needs --baseline FILE") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        // A refresh replaces the values and keeps a tolerance or ceiling set by hand.
        var baseline = EvalBaseline(metrics: metrics)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let existing = try? JSONDecoder().decode(EvalBaseline.self, from: data)
        {
            baseline.tolerance = existing.tolerance
            baseline.maximumLatencyMs = existing.maximumLatencyMs
        }
        try encoder.encode(baseline).write(to: URL(fileURLWithPath: path))
    } catch {
        fail("Cannot write \(path): \(error)")
    }
    print("Baseline written to \(path)")
} else if let path = options.baseline {
    regressions = load(EvalBaseline.self, path).regressions(of: metrics)
}

let report = metrics.report(title: title, regressions: regressions)
print(report, terminator: "")
if let path = options.report {
    do {
        try Data(report.utf8).write(to: URL(fileURLWithPath: path))
    } catch {
        fail("Cannot write \(path): \(error)")
    }
}
exit(regressions.isEmpty ? 0 : 1)

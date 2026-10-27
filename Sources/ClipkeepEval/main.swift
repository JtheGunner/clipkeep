import ClipkeepCore
import Foundation

// clipkeep-eval: measures search and session quality on a corpus and a gold set.
//
//   clipkeep-eval                              synthetic corpus, compared with eval/baseline.json
//   clipkeep-eval --write-baseline             store the current values as the baseline
//   clipkeep-eval --text notes.txt --gold g.json   an imported text file and your own gold set
//   options: --corpus FILE  --gold FILE  --baseline FILE  --report FILE

struct Options {
    var corpus = "eval/synthetic-corpus.json"
    var gold = "eval/synthetic-gold.json"
    var baseline: String? = "eval/baseline.json"
    var text: String?
    var report: String?
    var writeBaseline = false
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
            // Your own data has no baseline unless one is named.
            options.baseline = nil
        case "--report": options.report = value()
        case "--write-baseline": options.writeBaseline = true
        default: fail("Unknown option \(argument)")
        }
    }
    return options
}

func load<T: Decodable>(_ type: T.Type, _ path: String) -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        fail("Cannot read \(path): \(error)")
    }
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
let gold = load(GoldSet.self, options.gold)
let metrics: EvalMetrics
let title: String
do {
    if let textPath = options.text {
        let text = try TextImporter.read(URL(fileURLWithPath: textPath))
        metrics = try EvalRunner.run(importing: text, gold: gold)
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
        try encoder.encode(EvalBaseline(metrics: metrics)).write(to: URL(fileURLWithPath: path))
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
    try? Data(report.utf8).write(to: URL(fileURLWithPath: path))
}
exit(regressions.isEmpty ? 0 : 1)

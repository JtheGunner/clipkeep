import Foundation

/// The outcome of running the snippet filter over a clipboard history.
public struct SnippetEvaluationReport: Sendable {
    public struct Entry: Sendable, Equatable {
        public let language: SnippetLanguage?
        public let text: String

        public init(language: SnippetLanguage?, text: String) {
            self.language = language
            self.text = text
        }
    }

    public let accepted: [Entry]
    /// Texts the filter rejected although they look like commands, code or multi-line text.
    public let rejectedCodeLike: [Entry]
    public let examined: Int

    public init(accepted: [Entry], rejectedCodeLike: [Entry], examined: Int) {
        self.accepted = accepted
        self.rejectedCodeLike = rejectedCodeLike
        self.examined = examined
    }

    /// Plain text for review. It contains copied content, so it must never be committed or logged.
    public func rendered() -> String {
        var output = "Examined \(examined) entries\n"
        output += section("Accepted (\(accepted.count))", accepted)
        output += section("Rejected but code-like (\(rejectedCodeLike.count))", rejectedCodeLike)
        return output
    }

    private func section(_ title: String, _ entries: [Entry]) -> String {
        var output = "\n== \(title) ==\n"
        for entry in entries {
            output += "\n[\(entry.language?.rawValue ?? "none")]\n\(entry.text)\n"
        }
        return output
    }
}

/// Measures the snippet filter against stored history, to tune its thresholds before the
/// collection is switched on.
public enum SnippetEvaluation {
    private static let minimumCodeLikeLines = 3

    public static func run(
        database: Database, rejectedLimit: Int = 50
    ) throws -> SnippetEvaluationReport {
        let texts = try database.read { connection in
            try connection.query(
                """
                SELECT text FROM contents
                WHERE deleted_at IS NULL AND kind != ?
                ORDER BY last_copied_at DESC, id DESC
                """, [.text(ContentKind.secret.rawValue)]
            ) { $0.text(0) }
        }
        let anonymizer = SnippetAnonymizer()
        var accepted: [SnippetEvaluationReport.Entry] = []
        var rejected: [SnippetEvaluationReport.Entry] = []
        for original in texts {
            let text = anonymizer.anonymize(original)
            if let language = SnippetFilter.evaluate(text) {
                accepted.append(.init(language: language, text: text))
            } else if rejected.count < rejectedLimit, isCodeLike(text) {
                rejected.append(.init(language: nil, text: text))
            }
        }
        return SnippetEvaluationReport(
            accepted: accepted, rejectedCodeLike: rejected, examined: texts.count)
    }

    private static func isCodeLike(_ text: String) -> Bool {
        let lineCount = text.split(whereSeparator: \.isNewline).count
        // Tiny single-line texts such as `ls` are rejected by design; listing them is noise.
        if lineCount <= 1, text.count < SnippetFilter.Threshold.minimumSingleLineLength {
            return false
        }
        let kind = ContentClassifier.classify(text)
        return kind == .command || kind == .code || lineCount >= minimumCodeLikeLines
    }
}

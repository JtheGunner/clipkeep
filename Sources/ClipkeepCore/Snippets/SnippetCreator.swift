import Foundation

public enum SnippetCreateOutcome: Sendable, Equatable {
    /// A new snippet was stored.
    case created(Int64)
    /// The text became a variant of (or matched) this existing snippet.
    case joined(Int64)
    /// The text is empty or only whitespace.
    case empty
    /// The text is far larger than a snippet; nothing was stored.
    case tooLarge
    /// The anonymised text still contained something the detector flags; nothing was stored.
    case residualSecret
}

/// Adds a snippet typed in by hand. Like every other way in, the text is anonymised first and a
/// residual secret blocks it; unlike capture, the filter's verdict does not apply and the
/// chosen language is trusted.
public struct SnippetCreator: Sendable {
    private let store: SnippetStore
    private let anonymizer: SnippetAnonymizer
    private let residualDetector: SecretDetector

    public init(
        store: SnippetStore, anonymizer: SnippetAnonymizer = SnippetAnonymizer(),
        residualDetector: SecretDetector = SecretDetector()
    ) {
        self.store = store
        self.anonymizer = anonymizer
        self.residualDetector = residualDetector
    }

    /// The language the filter recognises in `text`, shell when it recognises none.
    public func guessLanguage(_ text: String) -> SnippetLanguage {
        SnippetFilter.evaluate(text) ?? .shell
    }

    /// Stores `text`. A matching deleted snippet is brought back. The comment is set on a new
    /// snippet, and on a joined one only when it has no comment yet.
    public func create(
        text: String, language: SnippetLanguage, comment: String?
    ) throws -> SnippetCreateOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        guard text.utf8.count <= SnippetCapture.maximumSourceBytes else { return .tooLarge }

        let anonymised = anonymizer.anonymize(text)
        guard anonymised.utf8.count <= SnippetFilter.Threshold.maximumBytes else {
            return .tooLarge
        }
        // Fail closed, as in live capture: a secret left after anonymising is never stored.
        guard !residualDetector.containsSecret(in: anonymised) else { return .residualSecret }

        let outcome = try store.add(
            text: anonymised, language: language, origin: .manual, appName: nil,
            overridingRejection: true)
        switch outcome {
        case .inserted(let id):
            try applyComment(comment, to: id, onlyIfMissing: false)
            return .created(id)
        case .bumped(let id), .unchanged(let id):
            try applyComment(comment, to: id, onlyIfMissing: true)
            return .joined(id)
        // Cannot happen while the rejection is overridden.
        case .rejected:
            return .empty
        }
    }

    private func applyComment(_ comment: String?, to id: Int64, onlyIfMissing: Bool) throws {
        guard let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if onlyIfMissing, let existing = try store.snippet(id: id), existing.comment != nil {
            return
        }
        _ = try store.setComment(id: id, comment: comment)
    }
}

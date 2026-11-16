import Foundation

public enum SnippetCreateOutcome: Sendable, Equatable {
    /// A new snippet was stored.
    case created(Int64)
    /// The text became a variant of (or matched) this existing snippet. `commentKept` is true
    /// when the snippet's existing comment was kept and the typed one was not applied.
    case joined(Int64, commentKept: Bool)
    /// The text is empty or only whitespace.
    case empty
    /// The text is far larger than a snippet; nothing was stored.
    case tooLarge
    /// The anonymised text still contained something the detector flags; nothing was stored.
    case residualSecret
    /// The anonymised comment still contained something the detector flags; nothing was stored.
    case commentResidualSecret
}

public enum SnippetCommentOutcome: Sendable, Equatable {
    /// The comment was stored, anonymised and trimmed.
    case saved
    /// The comment was empty, so the snippet has none now.
    case cleared
    /// The anonymised comment still contained something the detector flags; the stored comment
    /// is unchanged.
    case residualSecret
    /// No snippet has this id.
    case notFound
}

/// Adds a snippet typed in by hand and writes snippet comments. Like every other way in, text
/// and comment are anonymised first and a residual secret blocks them; unlike capture, the
/// filter's verdict does not apply and the chosen language is trusted.
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
        // Checked before anything is stored, so a refused comment leaves no snippet behind.
        let typedComment: String?
        switch prepared(comment) {
        case .refused: return .commentResidualSecret
        case .none: typedComment = nil
        case .text(let text): typedComment = text
        }

        let outcome = try store.add(
            text: anonymised, language: language, origin: .manual, appName: nil,
            overridingRejection: true)
        switch outcome {
        case .inserted(let id):
            if let typedComment { _ = try store.setComment(id: id, comment: typedComment) }
            return .created(id)
        case .bumped(let id), .unchanged(let id):
            guard let typedComment else { return .joined(id, commentKept: false) }
            if let existing = try store.snippet(id: id)?.comment {
                return .joined(id, commentKept: existing != typedComment)
            }
            _ = try store.setComment(id: id, comment: typedComment)
            return .joined(id, commentKept: false)
        // Cannot happen while the rejection is overridden.
        case .rejected:
            return .empty
        }
    }

    /// Sets or clears the comment of a snippet. Every comment write goes through here: the
    /// comment is anonymised, and one with a residual secret is refused.
    public func setComment(id: Int64, comment: String?) throws -> SnippetCommentOutcome {
        let stored: String?
        switch prepared(comment) {
        case .refused: return .residualSecret
        case .none: stored = nil
        case .text(let text): stored = text
        }
        guard try store.setComment(id: id, comment: stored) else { return .notFound }
        return stored == nil ? .cleared : .saved
    }

    private enum PreparedComment {
        case none
        case text(String)
        /// A secret survived anonymising.
        case refused
    }

    /// The comment as it would be stored: anonymised, trimmed and capped.
    private func prepared(_ comment: String?) -> PreparedComment {
        let anonymised = anonymizer.anonymize(comment ?? "")
        guard !residualDetector.containsSecret(in: anonymised) else { return .refused }
        return SnippetStore.storedComment(anonymised).map(PreparedComment.text) ?? .none
    }
}

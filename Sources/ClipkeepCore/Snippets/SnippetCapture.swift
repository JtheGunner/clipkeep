import Foundation

public enum SnippetCaptureError: Error, Equatable {
    /// The anonymised text still contained something the detector flags; the snippet was dropped.
    case residualSecret
}

/// Collects code-like copies as snippets while the history pipeline runs. It never throws and
/// never blocks the history: failures go to `onError`.
public struct SnippetCapture: Sendable {
    /// Texts up to this many times the filter's byte cap are still anonymised before judging.
    static let sizeSlackFactor = 4

    private let store: SnippetStore
    private let control: SnippetCaptureControl
    private let anonymizer: SnippetAnonymizer
    private let residualDetector: SecretDetector
    private let onError: @Sendable (Error) -> Void

    public init(
        store: SnippetStore, control: SnippetCaptureControl,
        anonymizer: SnippetAnonymizer = SnippetAnonymizer(),
        residualDetector: SecretDetector = SecretDetector(),
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.residualDetector = residualDetector
        self.store = store
        self.control = control
        self.anonymizer = anonymizer
        self.onError = onError
    }

    /// Secrets are replaced by placeholders before the text is judged or stored, so an
    /// unanonymised secret never reaches the store.
    public func capture(text: String, context: CopyContext, at date: Date) {
        guard control.isEnabled else { return }
        // The secret scan is the costly part, so texts far above the filter's cap skip it. The
        // slack covers anonymising shrinking a text (a private key block becomes a short
        // placeholder); the filter's own cap stays the authority for what is stored.
        guard text.utf8.count <= SnippetFilter.Threshold.maximumBytes * Self.sizeSlackFactor
        else { return }
        let anonymised = anonymizer.anonymize(text)
        guard let language = SnippetFilter.evaluate(anonymised) else { return }
        // Fail closed: if the detector still finds a secret after anonymising, the redaction
        // missed part of it. The scan only runs for texts the filter accepted (at most its
        // byte cap), so its cost stays bounded. The error carries no content.
        guard !residualDetector.containsSecret(in: anonymised) else {
            onError(SnippetCaptureError.residualSecret)
            return
        }
        do {
            _ = try store.add(
                text: anonymised, language: language, origin: .auto, appName: context.appName,
                at: date)
        } catch {
            onError(error)
        }
    }
}

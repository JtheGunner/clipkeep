import Foundation

/// Collects code-like copies as snippets while the history pipeline runs. It never throws and
/// never blocks the history: failures go to `onError`.
public struct SnippetCapture: Sendable {
    private let store: SnippetStore
    private let control: SnippetCaptureControl
    private let anonymizer: SnippetAnonymizer
    private let onError: @Sendable (Error) -> Void

    public init(
        store: SnippetStore, control: SnippetCaptureControl,
        anonymizer: SnippetAnonymizer = SnippetAnonymizer(),
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.store = store
        self.control = control
        self.anonymizer = anonymizer
        self.onError = onError
    }

    /// Secrets are replaced by placeholders before the text is judged or stored, so an
    /// unanonymised secret never reaches the store.
    public func capture(text: String, context: CopyContext, at date: Date) {
        guard control.isEnabled else { return }
        let anonymised = anonymizer.anonymize(text)
        guard let language = SnippetFilter.evaluate(anonymised) else { return }
        do {
            _ = try store.add(
                text: anonymised, language: language, origin: .auto, appName: context.appName,
                at: date)
        } catch {
            onError(error)
        }
    }
}

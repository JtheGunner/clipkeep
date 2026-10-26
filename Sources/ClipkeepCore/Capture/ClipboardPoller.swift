import Foundation

/// Polls the pasteboard's `changeCount` and feeds each new copy through the pipeline.
/// Not thread-safe: call `poll` from one serial queue only.
public final class ClipboardPoller: @unchecked Sendable {
    private let pasteboard: any PasteboardReading
    private let source: any SourceAppProviding
    private let pipeline: CapturePipeline
    private let onError: @Sendable (Error) -> Void
    private var lastChangeCount: Int

    /// The pasteboard content present at start is the baseline and is not captured.
    public init(
        pasteboard: any PasteboardReading, source: any SourceAppProviding,
        pipeline: CapturePipeline,
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.pasteboard = pasteboard
        self.source = source
        self.pipeline = pipeline
        self.onError = onError
        lastChangeCount = pasteboard.changeCount
    }

    /// Returns the outcome when the pasteboard changed since the last call, nil otherwise.
    /// A failing store reports through `onError` and drops that copy; polling continues.
    @discardableResult
    public func poll(now: Date = Date()) -> CaptureOutcome? {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current
        let snapshot = pasteboard.snapshot()
        do {
            return try pipeline.process(snapshot, source: source.currentSource(), at: now)
        } catch {
            onError(error)
            return nil
        }
    }
}

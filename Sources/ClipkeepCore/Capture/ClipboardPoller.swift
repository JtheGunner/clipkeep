import Foundation

/// Polls the pasteboard's `changeCount` and feeds each new copy through the pipeline.
/// Not thread-safe: call `poll` from one serial queue only.
public final class ClipboardPoller: @unchecked Sendable {
    private let pasteboard: any PasteboardReading
    private let source: any SourceAppProviding
    private let pipeline: CapturePipeline
    private let onError: @Sendable (Error) -> Void
    private var lastChangeCount: Int
    private var lastPollAt: Date

    /// The pasteboard content present at start is the baseline and is not captured.
    public init(
        pasteboard: any PasteboardReading, source: any SourceAppProviding,
        pipeline: CapturePipeline,
        now: Date = Date(), onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.pasteboard = pasteboard
        self.source = source
        self.pipeline = pipeline
        self.onError = onError
        lastChangeCount = pasteboard.changeCount
        lastPollAt = now
    }

    /// Returns the outcome when the pasteboard changed since the last call, nil otherwise (also
    /// when the pasteboard changed while being read; the next call handles it). A failing store
    /// reports through `onError` and drops that copy; polling continues.
    @discardableResult
    public func poll(now: Date = Date()) -> CaptureOutcome? {
        let windowStart = lastPollAt
        guard pasteboard.changeCount != lastChangeCount else {
            lastPollAt = now
            return nil
        }
        // While paused the pasteboard is not even read, and the change is forgotten for good.
        if pipeline.control.isPaused {
            lastChangeCount = pasteboard.changeCount
            lastPollAt = now
            return .skipped(.paused)
        }
        // A snapshot that failed keeps the window open, so the retry still covers the apps that
        // were frontmost since the last processed poll.
        guard let snapshot = pasteboard.snapshot() else { return nil }
        lastPollAt = now
        lastChangeCount = snapshot.changeCount
        do {
            return try pipeline.process(
                snapshot, sources: source.sources(from: windowStart, to: now), at: now)
        } catch {
            onError(error)
            return nil
        }
    }
}

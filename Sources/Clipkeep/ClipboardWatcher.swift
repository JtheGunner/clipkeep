import ClipkeepCore
import Dispatch

/// Polls the pasteboard four times a second on a private queue, so the main thread stays free.
final class ClipboardWatcher: @unchecked Sendable {
    private static let interval: DispatchTimeInterval = .milliseconds(250)

    private let queue = DispatchQueue(label: "li.wuermli.clipkeep.watcher", qos: .utility)
    private let poller: ClipboardPoller
    private var timer: DispatchSourceTimer?

    init(poller: ClipboardPoller) {
        self.poller = poller
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + Self.interval, repeating: Self.interval,
                leeway: .milliseconds(50))
            timer.setEventHandler { [poller] in poller.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }
}

import AppKit
import ClipkeepCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "capture")

    private var statusItemController: StatusItemController?
    private var watcher: ClipboardWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            launchAtLogin: LaunchAtLoginController(service: SystemLoginItemService())
        )
        startCapture()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
    }

    /// Without a database the app still runs, it just records nothing.
    private func startCapture() {
        do {
            let database = try AppDatabase.open()
            let pipeline = CapturePipeline(store: ContentStore(database: database))
            let poller = ClipboardPoller(
                pasteboard: SystemPasteboard(), source: FrontmostApplicationSource(),
                pipeline: pipeline,
                onError: { error in
                    // Never log copied content, only the error.
                    Self.logger.error(
                        "Capture failed: \(String(describing: error), privacy: .public)")
                })
            let watcher = ClipboardWatcher(poller: poller)
            watcher.start()
            self.watcher = watcher
        } catch {
            Self.logger.error("Capture disabled: \(String(describing: error), privacy: .public)")
        }
    }
}

import AppKit
import ClipkeepCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "capture")

    private var statusItemController: StatusItemController?
    private var watcher: ClipboardWatcher?
    private let systemContext = SystemContext()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            launchAtLogin: LaunchAtLoginController(service: SystemLoginItemService()),
            systemContext: systemContext
        )
        startCapture()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
    }

    /// Opens the database off the main thread (the Keychain may prompt). Without a database the
    /// app keeps running, shows the problem in its menu and records nothing.
    private func startCapture() {
        let tracker = FrontmostApplicationTracker()
        let systemContext = self.systemContext
        Task.detached(priority: .utility) { [weak self] in
            do {
                let database = try AppDatabase.open()
                let control = try CaptureControl(settings: SettingsStore(database: database))
                let poller = ClipboardPoller(
                    pasteboard: SystemPasteboard(), source: tracker,
                    pipeline: CapturePipeline(
                        store: ContentStore(database: database),
                        contextDetails: ContextReader(
                            environment: systemContext.environment,
                            readsSafari: { StatusItemController.readsSafari }),
                        control: control),
                    onError: { error in
                        // Never log copied content, only the error.
                        Self.logger.error(
                            "Capture failed: \(String(describing: error), privacy: .public)")
                    })
                let watcher = ClipboardWatcher(poller: poller)
                watcher.start()
                await self?.captureStarted(watcher, control: control)
            } catch {
                Self.logger.error(
                    "Capture disabled: \(String(describing: error), privacy: .public)")
                await self?.captureFailed()
            }
        }
    }

    private func captureStarted(_ watcher: ClipboardWatcher, control: CaptureControl) {
        self.watcher = watcher
        statusItemController?.attach(control: control)
    }

    private func captureFailed() {
        statusItemController?.showCaptureProblem(
            "Aufzeichnung inaktiv: Datenbank konnte nicht geöffnet werden")
    }
}

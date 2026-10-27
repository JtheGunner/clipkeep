import AppKit
import Carbon.HIToolbox
import ClipkeepCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "capture")

    private var statusItemController: StatusItemController?
    private var watcher: ClipboardWatcher?
    private var bitwarden: BitwardenSync?
    private var palette: PaletteController?
    private var history: HistoryWindowController?
    private var importer: ImportWindowController?
    private var paletteHotKey: GlobalHotKey?
    private let systemContext = SystemContext()
    private let secretNotifier = SecretNotifier()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The delegate must exist before launch ends to receive the action that started the app.
        secretNotifier.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            launchAtLogin: LaunchAtLoginController(service: SystemLoginItemService()),
            systemContext: systemContext
        )
        startCapture()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        lockBitwardenBeforeExit()
    }

    /// Opens the database off the main thread (the Keychain may prompt). Without a database the
    /// app keeps running, shows the problem in its menu and records nothing.
    private func startCapture() {
        let tracker = FrontmostApplicationTracker()
        let systemContext = self.systemContext
        let notifier = secretNotifier
        Task.detached(priority: .utility) { [weak self] in
            do {
                let database = try AppDatabase.open()
                let control = try CaptureControl(settings: SettingsStore(database: database))
                let store = ContentStore(database: database)
                let parker = SecretParker(
                    database: database, store: store, vault: KeychainSecretVault(),
                    onError: { error in
                        Self.logger.error(
                            "Parking a secret failed: \(String(describing: error), privacy: .public)"
                        )
                    },
                    onParked: { notifier.secretParked($0) })
                // Before capture starts: remove Keychain items left behind by an interrupted park.
                do {
                    _ = try parker.reconcile()
                } catch {
                    Self.logger.error(
                        "Reconciling parked secrets failed: \(String(describing: error), privacy: .public)"
                    )
                }
                let bitwarden = BitwardenSync(client: BitwardenCLIClient(), parker: parker)
                notifier.setUndoHandler { id in
                    do {
                        try await bitwarden.markNotSecret(id: id)
                        return true
                    } catch {
                        Self.logger.error(
                            "Undo failed: \(String(describing: error), privacy: .public)")
                        return false
                    }
                }
                let poller = ClipboardPoller(
                    pasteboard: SystemPasteboard(), source: tracker,
                    pipeline: CapturePipeline(
                        store: store, secretSink: parker,
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
                MaintenanceScheduler.start(database: database)
                await self?.captureStarted(
                    watcher, control: control, bitwarden: bitwarden, secrets: parker,
                    search: PaletteSearch(database: database),
                    history: HistoryWindowController(
                        browser: HistoryBrowser(database: database),
                        search: SearchService(database: database),
                        actions: ItemActions(database: database),
                        exporter: MarkdownExporter(database: database)),
                    importer: ImportWindowController(
                        importer: TextImporter(
                            database: database,
                            // Its own parker: an import of many secrets must not raise one
                            // notification per secret.
                            secretSink: SecretParker(
                                database: database,
                                store: ContentStore(database: database, sessions: nil),
                                vault: KeychainSecretVault(),
                                onError: { error in
                                    Self.logger.error(
                                        "Parking an imported secret failed: \(String(describing: error), privacy: .public)"
                                    )
                                }))))
            } catch {
                Self.logger.error(
                    "Capture disabled: \(String(describing: error), privacy: .public)")
                await self?.captureFailed()
            }
        }
    }

    /// Locks the vault so the session key does not outlive the app; waits briefly for `bw`.
    private func lockBitwardenBeforeExit() {
        guard let bitwarden else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await bitwarden.lock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    private func captureStarted(
        _ watcher: ClipboardWatcher, control: CaptureControl, bitwarden: BitwardenSync,
        secrets: SecretParker, search: PaletteSearch,
        history: HistoryWindowController, importer: ImportWindowController
    ) {
        self.watcher = watcher
        self.bitwarden = bitwarden
        statusItemController?.attach(control: control)
        statusItemController?.attach(bitwarden: bitwarden)
        statusItemController?.attach(secrets: secrets)
        self.history = history
        statusItemController?.attach(history: history)
        self.importer = importer
        statusItemController?.attach(importer: importer)
        let palette = PaletteController(search: search)
        self.palette = palette
        // Control + Option + V.
        paletteHotKey = GlobalHotKey(
            keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey,
            action: { [weak palette] in palette?.toggle() })
        statusItemController?.attach(
            palette: palette, hotKeyRegistered: paletteHotKey != nil)
    }

    private func captureFailed() {
        statusItemController?.showCaptureProblem(
            "Aufzeichnung inaktiv: Datenbank oder Einstellungen nicht lesbar")
    }
}

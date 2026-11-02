import AppKit
import ClipkeepCore

/// Owns the menu bar icon and its menu. The app has no Dock icon and no window.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let launchAtLogin: LaunchAtLoginController
    private let launchAtLoginItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let captureItem = NSMenuItem()
    private let pasteboardAccess: any PasteboardAccessProvider
    private let pasteboardItem = NSMenuItem()
    private let systemContext: SystemContext
    private let accessibilityItem = NSMenuItem()
    private let automationItem = NSMenuItem()
    private let safariItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let ignoreAppItem = NSMenuItem()
    private let ignoredAppsItem = NSMenuItem()
    private let bitwardenItem = NSMenuItem()
    private let bitwardenStatusItem = NSMenuItem()
    private let bitwardenUnlockItem = NSMenuItem()
    private let bitwardenTransferItem = NSMenuItem()
    private let bitwardenLockItem = NSMenuItem()
    private let bitwardenMessageItem = NSMenuItem()
    private let paletteItem = NSMenuItem()
    private var palette: PaletteController?
    private let historyItem = NSMenuItem()
    private let importItem = NSMenuItem()
    private let removeImportItem = NSMenuItem()
    private var importer: ImportWindowController?
    private var history: HistoryWindowController?
    private let exceptionsItem = NSMenuItem()
    private var secrets: SecretParker?
    private var control: CaptureControl?
    /// Whether the accessibility dialog was shown since this launch; kept in memory only, so a
    /// reset of the permission is handled by the next launch.
    private var hasAskedForAccessibility = false
    private var bitwarden: BitwardenSync?
    private var fatalProblem: String?

    init(
        launchAtLogin: LaunchAtLoginController, systemContext: SystemContext,
        pasteboardAccess: any PasteboardAccessProvider = SystemPasteboardAccessProvider()
    ) {
        self.launchAtLogin = launchAtLogin
        self.systemContext = systemContext
        self.pasteboardAccess = pasteboardAccess
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard", accessibilityDescription: AppInfo.name)
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        paletteItem.title = "Suchpalette öffnen"
        paletteItem.target = self
        paletteItem.action = #selector(openPalette)
        paletteItem.isEnabled = false
        menu.addItem(paletteItem)

        historyItem.title = "Verlauf öffnen …"
        historyItem.target = self
        historyItem.action = #selector(openHistory)
        historyItem.isEnabled = false
        menu.addItem(historyItem)

        importItem.title = "Textdatei importieren …"
        importItem.target = self
        importItem.action = #selector(openImport)
        importItem.isEnabled = false
        menu.addItem(importItem)
        removeImportItem.title = "Import löschen …"
        removeImportItem.target = self
        removeImportItem.action = #selector(openImportRemoval)
        removeImportItem.isEnabled = false
        menu.addItem(removeImportItem)
        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        pauseItem.isEnabled = false
        menu.addItem(pauseItem)
        ignoreAppItem.target = self
        ignoreAppItem.action = #selector(ignoreFrontmostApp)
        ignoreAppItem.isEnabled = false
        menu.addItem(ignoreAppItem)
        ignoredAppsItem.title = "Ignorieren"
        ignoredAppsItem.submenu = NSMenu()
        ignoredAppsItem.isHidden = true
        menu.addItem(ignoredAppsItem)
        menu.addItem(.separator())

        paletteItem.image = Symbols.image("magnifyingglass", nil)
        historyItem.image = Symbols.image("clock", nil)
        importItem.image = Symbols.image("square.and.arrow.down", nil)
        removeImportItem.image = Symbols.image("trash", nil)
        ignoreAppItem.image = Symbols.image("nosign", nil)

        launchAtLoginItem.title = "Beim Anmelden starten"
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchAtLoginItem)

        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)

        captureItem.isEnabled = false
        captureItem.isHidden = true
        menu.addItem(captureItem)

        pasteboardItem.target = self
        pasteboardItem.action = #selector(openPasteboardSettings)
        pasteboardItem.isHidden = true
        menu.addItem(pasteboardItem)

        menu.addItem(.separator())
        accessibilityItem.target = self
        accessibilityItem.action = #selector(openAccessibilitySettings)
        menu.addItem(accessibilityItem)
        automationItem.target = self
        automationItem.action = #selector(openAutomationSettings)
        menu.addItem(automationItem)
        safariItem.title = "Safari-Kontext lesen (private Fenster nicht erkennbar)"
        safariItem.target = self
        safariItem.action = #selector(toggleSafari)
        menu.addItem(safariItem)

        menu.addItem(.separator())
        exceptionsItem.title = "Secret-Ausnahmen"
        exceptionsItem.submenu = NSMenu()
        exceptionsItem.isHidden = true
        menu.addItem(exceptionsItem)
        bitwardenItem.title = "Bitwarden"
        bitwardenItem.submenu = makeBitwardenMenu()
        bitwardenItem.isHidden = true
        menu.addItem(bitwardenItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Clipkeep beenden", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.image = Symbols.image("xmark.circle", nil)
        menu.addItem(quit)
        return menu
    }

    private func makeBitwardenMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        bitwardenStatusItem.isEnabled = false
        menu.addItem(bitwardenStatusItem)
        bitwardenMessageItem.isEnabled = false
        bitwardenMessageItem.isHidden = true
        menu.addItem(bitwardenMessageItem)
        menu.addItem(.separator())
        bitwardenUnlockItem.title = "Entsperren und Secrets übertragen …"
        bitwardenUnlockItem.target = self
        bitwardenUnlockItem.action = #selector(unlockBitwarden)
        menu.addItem(bitwardenUnlockItem)
        bitwardenTransferItem.title = "Geparkte Secrets jetzt übertragen"
        bitwardenTransferItem.target = self
        bitwardenTransferItem.action = #selector(transferToBitwarden)
        menu.addItem(bitwardenTransferItem)
        bitwardenLockItem.title = "Sperren"
        bitwardenLockItem.target = self
        bitwardenLockItem.action = #selector(lockBitwarden)
        menu.addItem(bitwardenLockItem)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshBitwarden()
        refreshExceptions()
        launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
        let paused = control?.isPaused ?? false
        pauseItem.title = paused ? "Aufzeichnung fortsetzen" : "Aufzeichnung pausieren"
        pauseItem.image = Symbols.image(paused ? "play" : "pause", nil)
        let front = Self.frontmostForeignApp()
        ignoreAppItem.title = front.map { "„\($0.name)“ ignorieren" } ?? "Frontmost-App ignorieren"
        ignoreAppItem.isEnabled = control != nil && front != nil
        captureItem.title = fatalProblem ?? ""
        captureItem.isHidden = fatalProblem == nil
        refreshPasteboardAccess()
        refreshIgnoredApps()
        updateIcon()
        let status = systemContext.permissionStatus
        accessibilityItem.title =
            status.accessibilityGranted
            ? "Fenstertitel: erlaubt" : "Fenstertitel: Bedienungshilfen erlauben …"
        accessibilityItem.state = status.accessibilityGranted ? .on : .off
        accessibilityItem.isEnabled = !status.accessibilityGranted
        automationItem.title = Self.automationTitle(status.automation)
        safariItem.state = Self.readsSafari ? .on : .off
        errorItem.title = launchAtLogin.errorMessage ?? ""
        errorItem.isHidden = launchAtLogin.errorMessage == nil
    }

    /// Warns when macOS asks before each clipboard read or forbids it, since capture then sees nothing.
    private func refreshPasteboardAccess() {
        let hint = pasteboardAccess.current().hint
        pasteboardItem.title = hint ?? ""
        pasteboardItem.isHidden = hint == nil
    }

    @objc private func openPasteboardSettings() {
        openSettings("Privacy_Pasteboard")
    }

    /// Enables the pause and ignore items once the database is open.
    func attach(control: CaptureControl) {
        self.control = control
        pauseItem.isEnabled = true
        updateIcon()
    }

    func attach(palette: PaletteController, hotKeyRegistered: Bool) {
        self.palette = palette
        paletteItem.title =
            hotKeyRegistered
            ? "Suchpalette öffnen (⌃⌥V)" : "Suchpalette öffnen (Kurzbefehl ⌃⌥V ist belegt)"
        paletteItem.isEnabled = true
    }

    func attach(history: HistoryWindowController) {
        self.history = history
        historyItem.isEnabled = true
    }

    func attach(importer: ImportWindowController) {
        self.importer = importer
        importItem.isEnabled = true
        removeImportItem.isEnabled = true
    }

    @objc private func openImport() {
        DispatchQueue.main.async { [importer] in importer?.start() }
    }

    @objc private func openImportRemoval() {
        DispatchQueue.main.async { [importer] in importer?.removeImports() }
    }

    @objc private func openHistory() {
        DispatchQueue.main.async { [history] in history?.show() }
    }

    @objc private func openPalette() {
        // The menu is still closing; the panel opens right after.
        DispatchQueue.main.async { [palette] in palette?.show() }
    }

    func attach(secrets: SecretParker) {
        self.secrets = secrets
        exceptionsItem.isHidden = false
    }

    private func refreshExceptions() {
        guard let secrets else { return }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let exceptions = (try? secrets.exceptions()) ?? []
        for exception in exceptions {
            let item = NSMenuItem(
                title: "\(exception.label) – Ausnahme entfernen (Verlaufseintrag bleibt)",
                action: #selector(removeSecretException(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = exception.id
            submenu.addItem(item)
        }
        if exceptions.isEmpty {
            let none = NSMenuItem(title: "Keine Ausnahmen", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        exceptionsItem.submenu = submenu
    }

    @objc private func removeSecretException(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64 else { return }
        do {
            try secrets?.removeException(id: id)
        } catch {
            showSaveProblem()
        }
    }

    /// Enables the Bitwarden menu once the database is open.
    func attach(bitwarden: BitwardenSync) {
        self.bitwarden = bitwarden
        bitwardenItem.isHidden = false
    }

    private func refreshBitwarden() {
        guard let bitwarden else { return }
        Task { [weak self] in
            let result = await bitwarden.status()
            self?.showBitwardenStatus(result)
        }
    }

    private func showBitwardenStatus(_ result: Result<BitwardenStatus, BitwardenError>) {
        var unlocked = false
        var canUnlock = false
        switch result {
        case .success(.unlocked):
            bitwardenStatusItem.title = "Bitwarden: entsperrt"
            unlocked = true
        case .success(.locked):
            bitwardenStatusItem.title =
                "Bitwarden: gesperrt – geparkte Secrets warten im Schlüsselbund"
            canUnlock = true
        case .success(.loggedOut):
            bitwardenStatusItem.title = "Bitwarden: nicht angemeldet (im Terminal „bw login“)"
        case .failure(let error):
            bitwardenStatusItem.title = "Bitwarden: " + Self.describe(error)
            canUnlock = error != .notInstalled && error != .loggedOut
        }
        bitwardenUnlockItem.isEnabled = canUnlock
        bitwardenTransferItem.isEnabled = unlocked
        bitwardenLockItem.isEnabled = unlocked
    }

    private static func describe(_ error: BitwardenError) -> String {
        switch error {
        case .notInstalled:
            "Bitwarden-CLI („bw“) nicht installiert – geparkte Secrets bleiben im Schlüsselbund"
        case .loggedOut: "nicht angemeldet (im Terminal „bw login“)"
        case .locked: "gesperrt"
        case .invalidMasterPassword: "Masterpasswort falsch"
        case .offline: "keine Verbindung – geparkte Secrets bleiben im Schlüsselbund"
        case .timedOut: "keine Antwort – geparkte Secrets bleiben im Schlüsselbund"
        case .busy: "Übertragung läuft bereits"
        case .unexpectedOutput, .commandFailed:
            "nicht erreichbar – geparkte Secrets bleiben im Schlüsselbund"
        }
    }

    private func showTransfer(_ report: TransferReport) {
        var parts: [String] = []
        if report.transferred > 0 { parts.append("\(report.transferred) Secret(s) übertragen") }
        if let failure = report.failure {
            parts.append("\(report.remaining) warten noch: " + Self.describe(failure))
        } else if report.transferred == 0 {
            parts.append("Keine Secrets zu übertragen")
        }
        bitwardenMessageItem.title = parts.joined(separator: " · ")
        bitwardenMessageItem.isHidden = false
    }

    @objc private func unlockBitwarden() {
        guard let bitwarden else { return }
        let alert = NSAlert()
        alert.messageText = "Bitwarden entsperren"
        alert.informativeText =
            "Das Masterpasswort wird nur an Bitwarden übergeben und nicht gespeichert."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Entsperren")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else {
            return
        }
        let password = field.stringValue
        field.stringValue = ""
        Task { [weak self] in
            do {
                let report = try await bitwarden.unlock(masterPassword: password)
                self?.showTransfer(report)
            } catch let error as BitwardenError {
                self?.showBitwardenFailure(error)
            } catch {
                self?.showBitwardenFailure(.commandFailed)
            }
        }
    }

    @objc private func transferToBitwarden() {
        guard let bitwarden else { return }
        Task { [weak self] in
            do {
                self?.showTransfer(try await bitwarden.transferPending())
            } catch {
                self?.showBitwardenFailure(.commandFailed)
            }
        }
    }

    @objc private func lockBitwarden() {
        guard let bitwarden else { return }
        Task { await bitwarden.lock() }
    }

    private func showBitwardenFailure(_ error: BitwardenError) {
        bitwardenMessageItem.title = Self.describe(error)
        bitwardenMessageItem.isHidden = false
    }

    private func updateIcon() {
        let paused = control?.isPaused ?? false
        statusItem.button?.image = NSImage(
            systemSymbolName: paused ? "pause.circle" : "doc.on.clipboard",
            accessibilityDescription: paused ? "\(AppInfo.name) pausiert" : AppInfo.name)
    }

    @objc private func togglePause() {
        do {
            try control?.togglePause()
        } catch {
            // Pausing still took effect; only the saved state is missing.
            showSaveProblem()
        }
        updateIcon()
    }

    /// The app in front, unless it is Clipkeep itself or has no bundle identifier.
    private static func frontmostForeignApp() -> (bundleID: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier
        else { return nil }
        return (bundleID, app.localizedName ?? bundleID)
    }

    @objc private func ignoreFrontmostApp() {
        guard let front = Self.frontmostForeignApp() else { return }
        do {
            try control?.addIgnoredApp(front.bundleID)
        } catch {
            showSaveProblem()
        }
    }

    @objc private func addContentRule() {
        let alert = NSAlert()
        alert.messageText = "Inhalte ignorieren"
        alert.informativeText =
            "Kopien, auf die dieser reguläre Ausdruck passt, werden nicht gespeichert (geprüft werden die ersten 20 000 Zeichen)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "^intern-"
        alert.accessoryView = field
        alert.addButton(withTitle: "Hinzufügen")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else {
            return
        }
        do {
            try control?.addPattern(field.stringValue)
        } catch let error as CaptureControlError {
            showRuleError(error)
        } catch {
            showSaveProblem()
        }
    }

    @objc private func removeContentRule(_ sender: NSMenuItem) {
        guard let pattern = sender.representedObject as? String else { return }
        do {
            try control?.removePattern(pattern)
        } catch {
            showSaveProblem()
        }
    }

    private func showRuleError(_ error: CaptureControlError) {
        let alert = NSAlert()
        alert.messageText = "Regel nicht übernommen"
        switch error {
        case .invalidPattern: alert.informativeText = "Der reguläre Ausdruck ist ungültig."
        case .patternTooLong: alert.informativeText = "Der Ausdruck ist zu lang."
        case .patternTooSlow:
            alert.informativeText = "Der Ausdruck ist zu langsam auf normalem Text."
        case .tooManyPatterns: alert.informativeText = "Es sind höchstens 50 Regeln möglich."
        default: alert.informativeText = "Die Regel konnte nicht gespeichert werden."
        }
        alert.runModal()
    }

    /// Shown until the menu is opened again.
    private func showSaveProblem() {
        captureItem.title = "Einstellung konnte nicht gespeichert werden"
        captureItem.isHidden = false
    }

    @objc private func removeIgnoredApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        do {
            try control?.removeIgnoredApp(bundleID)
        } catch {
            showSaveProblem()
        }
    }

    /// Names installed apps the way Finder shows them, without the `.app` suffix.
    private static let appNames = AppNameResolver { bundleID in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path)
                .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        }
    }

    private func refreshIgnoredApps() {
        let rules = control?.rules ?? IgnoreRules()
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for bundleID in rules.apps.sorted() {
            let item = NSMenuItem(
                title: "\(Self.appNames.name(for: bundleID)) – entfernen",
                action: #selector(removeIgnoredApp(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = bundleID
            submenu.addItem(item)
        }
        for pattern in rules.patterns {
            let item = NSMenuItem(
                title: "/\(pattern)/ – entfernen", action: #selector(removeContentRule(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = pattern
            submenu.addItem(item)
        }
        if submenu.numberOfItems > 0 { submenu.addItem(.separator()) }
        let add = NSMenuItem(
            title: "Inhaltsregel hinzufügen …", action: #selector(addContentRule), keyEquivalent: ""
        )
        add.target = self
        add.isEnabled = control != nil
        submenu.addItem(add)
        ignoredAppsItem.submenu = submenu
        ignoredAppsItem.isHidden = false
    }

    /// Tells the user that nothing is being recorded, so history does not silently stay empty.
    func showCaptureProblem(_ message: String) {
        fatalProblem = message
        captureItem.title = message
        captureItem.isHidden = false
    }

    nonisolated static let readsSafariKey = "readsSafariContext"
    /// On unless the user turned it off. Safari's private windows cannot be told apart from
    /// normal ones, so the menu offers the switch.
    nonisolated static var readsSafari: Bool {
        UserDefaults.standard.object(forKey: readsSafariKey) as? Bool ?? true
    }

    private static func automationTitle(_ states: [String: AutomationState]) -> String {
        if states.isEmpty { return "Browser-Adressen: Automation erlauben …" }
        if states.values.contains(.denied) { return "Browser-Adressen: nicht erlaubt – öffnen …" }
        if states.values.contains(.notAsked) { return "Browser-Adressen: Automation erlauben …" }
        return "Browser-Adressen: erlaubt"
    }

    @objc private func toggleSafari() {
        UserDefaults.standard.set(!Self.readsSafari, forKey: Self.readsSafariKey)
    }

    @objc private func openAccessibilitySettings() {
        // Asking lists the app under Accessibility, which a reset of the permission removes. The
        // system dialog comes first; clicks after it open the settings pane as well.
        SystemContext.requestAccessibility()
        if hasAskedForAccessibility { openSettings("Privacy_Accessibility") }
        hasAskedForAccessibility = true
    }

    @objc private func openAutomationSettings() {
        Task.detached(priority: .userInitiated) {
            let states = SystemContext.requestAutomation()
            if states.isEmpty || states.values.contains(.denied) {
                await MainActor.run { self.openSettings("Privacy_Automation") }
            }
        }
    }

    private func openSettings(_ pane: String) {
        let address = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
    }
}

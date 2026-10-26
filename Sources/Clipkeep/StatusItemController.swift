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
    private let systemContext: SystemContext
    private let accessibilityItem = NSMenuItem()
    private let automationItem = NSMenuItem()
    private let safariItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let ignoreAppItem = NSMenuItem()
    private let ignoredAppsItem = NSMenuItem()
    private var control: CaptureControl?
    private var fatalProblem: String?

    init(launchAtLogin: LaunchAtLoginController, systemContext: SystemContext) {
        self.launchAtLogin = launchAtLogin
        self.systemContext = systemContext
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard", accessibilityDescription: AppInfo.name)
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

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
        let quit = NSMenuItem(
            title: "Clipkeep beenden", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
        let paused = control?.isPaused ?? false
        pauseItem.title = paused ? "Aufzeichnung fortsetzen" : "Aufzeichnung pausieren"
        let front = Self.frontmostForeignApp()
        ignoreAppItem.title = front.map { "„\($0.name)“ ignorieren" } ?? "Frontmost-App ignorieren"
        ignoreAppItem.isEnabled = control != nil && front != nil
        captureItem.title = fatalProblem ?? ""
        captureItem.isHidden = fatalProblem == nil
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

    /// Enables the pause and ignore items once the database is open.
    func attach(control: CaptureControl) {
        self.control = control
        pauseItem.isEnabled = true
        updateIcon()
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

    private func refreshIgnoredApps() {
        let rules = control?.rules ?? IgnoreRules()
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for bundleID in rules.apps.sorted() {
            let item = NSMenuItem(
                title: "\(bundleID) – entfernen", action: #selector(removeIgnoredApp(_:)),
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
    nonisolated static var readsSafari: Bool { UserDefaults.standard.bool(forKey: readsSafariKey) }

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
        // The first click shows the system prompt, later ones open the settings pane.
        let key = "accessibilityPromptShown"
        if UserDefaults.standard.bool(forKey: key) {
            openSettings("Privacy_Accessibility")
        } else {
            UserDefaults.standard.set(true, forKey: key)
            SystemContext.requestAccessibility()
        }
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

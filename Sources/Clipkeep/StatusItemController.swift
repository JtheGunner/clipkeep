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

    /// Tells the user that nothing is being recorded, so history does not silently stay empty.
    func showCaptureProblem(_ message: String) {
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

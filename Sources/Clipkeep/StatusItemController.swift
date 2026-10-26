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
        automationItem.title =
            status.automationDeniedBundleIDs.isEmpty
            ? "Browser-Adressen: Automation in den Systemeinstellungen prüfen …"
            : "Browser-Adressen: nicht erlaubt – Automation öffnen …"
        errorItem.title = launchAtLogin.errorMessage ?? ""
        errorItem.isHidden = launchAtLogin.errorMessage == nil
    }

    /// Tells the user that nothing is being recorded, so history does not silently stay empty.
    func showCaptureProblem(_ message: String) {
        captureItem.title = message
        captureItem.isHidden = false
    }

    @objc private func openAccessibilitySettings() {
        if !SystemContext.requestAccessibility() {
            openSettings("Privacy_Accessibility")
        }
    }

    @objc private func openAutomationSettings() {
        openSettings("Privacy_Automation")
    }

    private func openSettings(_ pane: String) {
        let address = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
    }
}

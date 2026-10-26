import AppKit
import ClipkeepCore

/// Owns the menu bar icon and its menu. The app has no Dock icon and no window.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let launchAtLogin: LaunchAtLoginController
    private let launchAtLoginItem = NSMenuItem()
    private let errorItem = NSMenuItem()

    init(launchAtLogin: LaunchAtLoginController) {
        self.launchAtLogin = launchAtLogin
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

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Clipkeep beenden", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
        errorItem.title = launchAtLogin.errorMessage ?? ""
        errorItem.isHidden = launchAtLogin.errorMessage == nil
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
    }
}

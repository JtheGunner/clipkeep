import AppKit
import ClipkeepCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            launchAtLogin: LaunchAtLoginController(service: SystemLoginItemService())
        )
    }
}

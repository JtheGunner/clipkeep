/// Toggles the login item and reports problems as a user-facing message instead of throwing.
@MainActor
public final class LaunchAtLoginController {
    private let service: any LoginItemService
    private var failureMessage: String?

    public init(service: any LoginItemService) {
        self.service = service
    }

    public var isEnabled: Bool { service.status == .enabled }

    /// Failure of the last toggle, or a hint when macOS waits for the user's approval.
    public var errorMessage: String? {
        if let failureMessage { return failureMessage }
        if service.status == .requiresApproval {
            return "Bitte in den Systemeinstellungen unter Anmeldeobjekte erlauben"
        }
        return nil
    }

    /// Registers when the item is off, otherwise unregisters, so a pending approval can be undone.
    public func toggle() {
        do {
            try service.setEnabled(service.status == .disabled)
            failureMessage = nil
        } catch {
            failureMessage = "Autostart nicht möglich: \(error.localizedDescription)"
        }
    }
}

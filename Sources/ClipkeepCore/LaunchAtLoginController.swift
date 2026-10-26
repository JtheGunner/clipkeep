/// Toggles the login item and reports failures as a user-facing message instead of throwing.
@MainActor
public final class LaunchAtLoginController {
    private let service: any LoginItemService
    public private(set) var errorMessage: String?

    public init(service: any LoginItemService) {
        self.service = service
    }

    public var isEnabled: Bool { service.isEnabled }

    /// Flips the current state; the message is cleared on success and set on failure.
    public func toggle() {
        do {
            try service.setEnabled(!service.isEnabled)
            errorMessage = nil
        } catch {
            errorMessage = "Autostart nicht möglich: \(error.localizedDescription)"
        }
    }
}

import ServiceManagement

public enum LoginItemStatus: Sendable, Equatable {
    case disabled
    case enabled
    /// Registered, but the user still has to approve it in System Settings > Login Items.
    case requiresApproval
}

/// Abstraction over the login-item registration so the UI can be tested without a bundle.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Registers the running app bundle as a login item via `SMAppService`.
/// Only works when started from a `.app` bundle, not from `swift run`.
public struct SystemLoginItemService: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

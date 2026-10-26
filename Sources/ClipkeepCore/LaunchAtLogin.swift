import ServiceManagement

/// Abstraction over the login-item registration so the UI can be tested without a bundle.
public protocol LoginItemService: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Registers the running app bundle as a login item via `SMAppService`.
/// Only works when started from a signed `.app` bundle, not from `swift run`.
public struct SystemLoginItemService: LoginItemService {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

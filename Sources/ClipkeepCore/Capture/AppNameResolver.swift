import Foundation

/// Turns a bundle identifier into the name a person knows the app by.
public struct AppNameResolver: Sendable {
    private let lookup: @Sendable (String) -> String?

    /// `lookup` returns the display name of an installed app, or nil when it is unknown.
    public init(lookup: @escaping @Sendable (String) -> String?) {
        self.lookup = lookup
    }

    /// The app's name, or the bundle identifier when the app is not installed or has no name.
    public func name(for bundleID: String) -> String {
        guard let name = lookup(bundleID)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return bundleID }
        return name
    }
}

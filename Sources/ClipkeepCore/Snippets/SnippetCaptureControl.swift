import Foundation

/// Whether copies are also collected as snippets. On unless the user switched it off; the
/// choice is kept in the settings table. Safe to use from any thread.
public final class SnippetCaptureControl: @unchecked Sendable {
    private static let enabledKey = "snippets.captureEnabled"

    private let settings: SettingsStore?
    private let lock = NSLock()
    private var enabled: Bool

    /// Loads the saved choice. A value that is neither `"0"` nor `"1"` throws, so collection
    /// does not run in a state the user never chose.
    public init(settings: SettingsStore) throws {
        self.settings = settings
        switch try settings.string(Self.enabledKey) {
        case nil, "1": enabled = true
        case "0": enabled = false
        case .some: throw CaptureControlError.corruptSetting(Self.enabledKey)
        }
    }

    /// Loads the saved choice, or falls back to collection switched off when it cannot be read,
    /// so a snippet setting problem never stops the history. `onError` gets the failure.
    public static func loadOrDisabled(
        settings: SettingsStore, onError: (Error) -> Void
    ) -> SnippetCaptureControl {
        do {
            return try SnippetCaptureControl(settings: settings)
        } catch {
            onError(error)
            return SnippetCaptureControl(enabled: false)
        }
    }

    /// In-memory control without persistence, for tests and previews.
    public init(enabled: Bool = true) {
        settings = nil
        self.enabled = enabled
    }

    public var isEnabled: Bool { lock.withLock { enabled } }

    /// Saves the choice first; if saving fails the current state stays and the error is thrown.
    public func setEnabled(_ value: Bool) throws {
        try settings?.set(value, for: Self.enabledKey)
        lock.withLock { enabled = value }
    }
}

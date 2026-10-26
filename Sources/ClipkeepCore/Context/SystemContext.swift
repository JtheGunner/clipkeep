import AppKit
import ApplicationServices
import Foundation

/// Which permissions the context features have, for the settings menu.
public struct ContextPermissionStatus: Sendable, Equatable {
    /// Needed for window titles.
    public let accessibilityGranted: Bool
    /// Bundle identifiers of browsers that refused Apple Events (needed for page addresses).
    public let automationDeniedBundleIDs: Set<String>
}

/// The real accessibility and Apple Event calls. Everything fails soft: without a permission
/// the details stay empty and capture goes on unchanged.
public final class SystemContext: @unchecked Sendable {
    /// Apple Event error "not authorized to send Apple events".
    private static let notAuthorizedError = -1743

    private let lock = NSLock()
    private var denied: Set<String> = []

    public init() {}

    public var environment: ContextEnvironment {
        ContextEnvironment(
            frontmostApp: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                    let bundleID = app.bundleIdentifier
                else { return nil }
                return .init(bundleID: bundleID, processID: app.processIdentifier)
            },
            windowTitle: { Self.windowTitle(ofProcess: $0) },
            browserAddress: { [self] script, bundleID in run(script, for: bundleID) })
    }

    public var permissionStatus: ContextPermissionStatus {
        ContextPermissionStatus(
            accessibilityGranted: AXIsProcessTrusted(),
            automationDeniedBundleIDs: lock.withLock { denied })
    }

    /// Shows the system prompt for accessibility access; returns whether it is granted already.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func windowTitle(ofProcess processID: Int32) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedWindowAttribute as CFString, &window)
                == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    private func run(_ source: String, for bundleID: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == Self.notAuthorizedError { lock.withLock { _ = denied.insert(bundleID) } }
            return nil
        }
        lock.withLock { _ = denied.remove(bundleID) }
        return result?.stringValue
    }
}

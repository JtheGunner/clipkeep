import AppKit
import ApplicationServices
import CoreServices
import Foundation

/// Whether Clipkeep may send Apple Events to one browser.
public enum AutomationState: Sendable, Equatable {
    case allowed
    case denied
    /// macOS has not asked yet; the first request shows the system prompt.
    case notAsked
}

/// Which permissions the context features have, for the settings menu.
public struct ContextPermissionStatus: Sendable, Equatable {
    /// Needed for window titles.
    public let accessibilityGranted: Bool
    /// State per running browser (needed for page addresses).
    public let automation: [String: AutomationState]
}

/// The real accessibility and Apple Event calls. Everything fails soft: without a permission
/// the details stay empty and capture goes on unchanged. Slow calls run on their own queue with
/// a deadline, so a hanging app or browser cannot stall the clipboard poller.
public final class SystemContext: @unchecked Sendable {
    private static let deadline: DispatchTimeInterval = .milliseconds(400)
    private static let accessibilityTimeout: Float = 0.2

    private let queue = DispatchQueue(label: "li.wuermli.clipkeep.context", qos: .utility)
    private let lock = NSLock()
    private var isBusy = false
    /// Compiled scripts, only touched on `queue`.
    private var scripts: [String: NSAppleScript] = [:]

    public init() {}

    public var environment: ContextEnvironment {
        ContextEnvironment(
            frontmostApp: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                    let bundleID = app.bundleIdentifier
                else { return nil }
                return .init(bundleID: bundleID, processID: app.processIdentifier)
            },
            windowTitle: { [self] processID in
                withDeadline { Self.windowTitle(ofProcess: processID) }
            },
            browserAddress: { [self] script, bundleID in
                // Never triggers the consent prompt: that only happens from the menu.
                guard Self.automationState(of: bundleID, ask: false) == .allowed else { return nil }
                return withDeadline { self.run(script, for: bundleID) }
            })
    }

    public var permissionStatus: ContextPermissionStatus {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .filter(BrowserCatalog.isBrowser)
        var states: [String: AutomationState] = [:]
        for bundleID in running {
            states[bundleID] = Self.automationState(of: bundleID, ask: false)
        }
        return ContextPermissionStatus(
            accessibilityGranted: AXIsProcessTrusted(), automation: states)
    }

    /// Shows the system prompt for accessibility access; returns whether it is granted already.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Asks macOS for Automation access to every running browser (system prompts) and returns
    /// the resulting states. Call off the main thread: the prompts block until answered.
    public static func requestAutomation() -> [String: AutomationState] {
        var states: [String: AutomationState] = [:]
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        for bundleID in running where BrowserCatalog.isBrowser(bundleID) {
            states[bundleID] = automationState(of: bundleID, ask: true)
        }
        return states
    }

    private static func automationState(of bundleID: String, ask: Bool) -> AutomationState? {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return nil }
        let status = AEDeterminePermissionToAutomateTarget(
            descriptor, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case Int(noErr): return .allowed
        case Int(errAEEventNotPermitted): return .denied
        case Int(errAEEventWouldRequireUserConsent): return .notAsked
        default: return nil  // not running or unknown
        }
    }

    /// Runs `body` on the context queue and waits at most `deadline`. Returns nil on timeout, and
    /// also immediately while an earlier call is still stuck, so one hang costs one copy's
    /// details instead of stalling every following copy.
    private func withDeadline<T: Sendable>(_ body: @escaping @Sendable () -> T?) -> T? {
        let claimed = lock.withLock { () -> Bool in
            if isBusy { return false }
            isBusy = true
            return true
        }
        guard claimed else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        queue.async { [self] in
            box.set(body())
            lock.withLock { isBusy = false }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.deadline) == .success else { return nil }
        return box.value
    }

    private static func windowTitle(ofProcess processID: Int32) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, accessibilityTimeout)
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedWindowAttribute as CFString, &window)
                == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let windowElement = window as! AXUIElement
        AXUIElementSetMessagingTimeout(windowElement, accessibilityTimeout)
        var title: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &title)
                == .success
        else { return nil }
        return title as? String
    }

    /// Only called on `queue`.
    private func run(_ source: String, for bundleID: String) -> String? {
        let script: NSAppleScript
        if let cached = scripts[bundleID] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { return nil }
            scripts[bundleID] = created
            script = created
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ value: T?) { lock.withLock { stored = value } }
}

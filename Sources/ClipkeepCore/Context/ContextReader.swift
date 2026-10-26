import Foundation

/// Adds details such as window title and browser address to the app that made a copy.
public protocol ContextDetailProviding: Sendable {
    func details(for source: CopyContext) -> CopyContext
}

/// The system calls behind `ContextReader`, replaceable in tests.
public struct ContextEnvironment: Sendable {
    public struct FrontApp: Sendable, Equatable {
        public let bundleID: String
        public let processID: Int32
        public init(bundleID: String, processID: Int32) {
            self.bundleID = bundleID
            self.processID = processID
        }
    }

    public var frontmostApp: @Sendable () -> FrontApp?
    /// Title of the focused window of a process; nil without permission or window.
    public var windowTitle: @Sendable (Int32) -> String?
    /// Runs an AppleScript for a browser and returns its text result; nil on any failure.
    public var browserAddress: @Sendable (_ script: String, _ bundleID: String) -> String?

    public init(
        frontmostApp: @escaping @Sendable () -> FrontApp?,
        windowTitle: @escaping @Sendable (Int32) -> String?,
        browserAddress: @escaping @Sendable (String, String) -> String?
    ) {
        self.frontmostApp = frontmostApp
        self.windowTitle = windowTitle
        self.browserAddress = browserAddress
    }
}

/// Reads window title and browser URL, but only while the source app is still frontmost, so a
/// detail is never attributed to the wrong app. Missing permissions leave the fields empty.
public struct ContextReader: ContextDetailProviding {
    private let environment: ContextEnvironment

    public init(environment: ContextEnvironment) {
        self.environment = environment
    }

    public func details(for source: CopyContext) -> CopyContext {
        guard let bundleID = source.appBundleID, let front = environment.frontmostApp(),
            front.bundleID == bundleID
        else { return source }
        var result = source
        result.windowTitle = ContextSanitizer.title(environment.windowTitle(front.processID))
        if let script = BrowserCatalog.script(forBundleID: bundleID) {
            result.url = ContextSanitizer.url(environment.browserAddress(script, bundleID))
        }
        return result
    }
}

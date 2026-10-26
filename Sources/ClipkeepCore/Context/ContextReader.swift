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
/// detail is never attributed to another app. Missing permissions leave the fields empty.
/// Details of private windows and details that look like secrets are dropped; the copy stays.
/// A tab or window switched within the same app right after the copy cannot be detected.
public struct ContextReader: ContextDetailProviding {
    private static let privateTitleMarkers = ["private browsing", "inprivate", "incognito"]

    private let environment: ContextEnvironment
    private let detector: SecretDetector
    private let readsSafari: @Sendable () -> Bool

    /// - Parameter readsSafari: whether Safari may be read; its private windows cannot be told
    ///   apart, so this is off unless the user opted in.
    public init(
        environment: ContextEnvironment, detector: SecretDetector = SecretDetector(),
        readsSafari: @escaping @Sendable () -> Bool = { false }
    ) {
        self.environment = environment
        self.detector = detector
        self.readsSafari = readsSafari
    }

    public func details(for source: CopyContext) -> CopyContext {
        guard let bundleID = source.appBundleID, let front = environment.frontmostApp(),
            front.bundleID == bundleID
        else { return source }
        if BrowserCatalog.isSafari(bundleID) && !readsSafari() { return source }

        var address: String?
        if let script = BrowserCatalog.script(forBundleID: bundleID) {
            let raw = environment.browserAddress(script, bundleID)
            if raw == BrowserCatalog.privateMarker { return source }
            // Without a confirmed normal window (no permission, timeout, error) a Chromium
            // title could belong to a private window, so nothing is read.
            if raw == nil && !BrowserCatalog.isSafari(bundleID) { return source }
            address = ContextSanitizer.url(raw)
        }
        let title = ContextSanitizer.title(environment.windowTitle(front.processID))
        if let title, Self.isPrivateTitle(title) { return source }

        var result = source
        result.windowTitle = title.flatMap { detector.containsSecret(in: $0) ? nil : $0 }
        result.url = address.flatMap { detector.containsSecret(in: $0) ? nil : $0 }
        return result
    }

    private static func isPrivateTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return privateTitleMarkers.contains { lowered.contains($0) }
    }
}

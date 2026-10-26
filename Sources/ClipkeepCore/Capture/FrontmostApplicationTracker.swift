import AppKit
import Foundation

/// Remembers which app was frontmost when, so a copy is attributed to the app that made it even
/// when the user switches away before the next poll. Needs to be created on the main thread.
public final class FrontmostApplicationTracker: SourceAppProviding, @unchecked Sendable {
    private static let capacity = 64

    private let lock = NSLock()
    private var activations: [(date: Date, context: CopyContext)]
    private var observer: NSObjectProtocol?

    public init(now: Date = Date()) {
        activations = [(now, Self.context(of: NSWorkspace.shared.frontmostApplication))]
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let app =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.record(Self.context(of: app), at: Date())
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func record(_ context: CopyContext, at date: Date) {
        lock.withLock {
            activations.append((date, context))
            if activations.count > Self.capacity { activations.removeFirst() }
        }
    }

    public func sources(from start: Date, to end: Date) -> [CopyContext] {
        lock.withLock {
            let atStart = activations.last { $0.date <= start } ?? activations.first
            let during = activations.filter { $0.date > start && $0.date <= end }
            var result: [CopyContext] = []
            for context in ([atStart].compactMap { $0 } + during).map(\.context)
            where result.last != context {
                result.append(context)
            }
            return result
        }
    }

    private static func context(of app: NSRunningApplication?) -> CopyContext {
        CopyContext(appBundleID: app?.bundleIdentifier, appName: app?.localizedName)
    }
}

import AppKit

/// Whether macOS lets this app read the clipboard without asking.
public enum PasteboardAccess: Equatable, Sendable {
    case allowed
    /// macOS asks before each read, or the user has not decided yet.
    case askEachTime
    case denied
    /// The setting cannot be queried (macOS before 15.4) or has an unknown value.
    case unknown

    /// Reading works silently, or the state cannot be judged. Only then is no hint needed.
    public var needsHint: Bool { self == .askEachTime || self == .denied }

    /// Menu text for a restricted state; nil when no hint is needed.
    public var hint: String? {
        switch self {
        case .askEachTime:
            "Zwischenablage: macOS fragt bei jedem Lesen – Clipkeep sieht Kopien evtl. nicht …"
        case .denied:
            "Zwischenablage: Lesen verboten – Clipkeep sieht keine Kopien …"
        case .allowed, .unknown: nil
        }
    }
}

/// Source of the current pasteboard access setting. Replaceable in tests.
public protocol PasteboardAccessProvider: Sendable {
    func current() -> PasteboardAccess
}

/// Reads `NSPasteboard.accessBehavior`, which exists from macOS 15.4.
public struct SystemPasteboardAccessProvider: PasteboardAccessProvider {
    public init() {}

    public func current() -> PasteboardAccess {
        guard #available(macOS 15.4, *) else { return .unknown }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return .allowed
        case .ask: return .askEachTime
        case .alwaysDeny: return .denied
        case .default: return .askEachTime
        @unknown default: return .unknown
        }
    }
}

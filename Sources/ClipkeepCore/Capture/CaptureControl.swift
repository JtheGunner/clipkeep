import Foundation

public enum CaptureControlError: Error, Equatable {
    case invalidPattern(String)
    case patternTooLong
    case tooManyPatterns
    case invalidBundleID
}

/// What the user chose to keep out of the history: apps and regular expressions on the content.
public struct IgnoreRules: Sendable, Equatable {
    public var apps: Set<String> = []
    public var patterns: [String] = []

    public init(apps: Set<String> = [], patterns: [String] = []) {
        self.apps = apps
        self.patterns = patterns
    }
}

/// Pause state and ignore rules. Changes take effect on the next copy without a restart and are
/// kept in the settings table. Safe to use from any thread.
public final class CaptureControl: @unchecked Sendable {
    public static let maximumPatterns = 50
    public static let maximumPatternLength = 500
    /// Longest stretch of content a rule looks at.
    static let maximumScannedCharacters = 20_000
    /// Time one copy may spend in rule matching before it counts as matched.
    static let matchBudget: TimeInterval = 0.05

    private static let pausedKey = "capture.paused"
    private static let appsKey = "capture.ignoredApps"
    private static let patternsKey = "capture.ignoredPatterns"

    private let settings: SettingsStore?
    private let lock = NSLock()
    private var paused: Bool
    private var currentRules: IgnoreRules
    private var compiled: [NSRegularExpression]

    /// Loads the saved state; patterns that no longer compile are skipped.
    public init(settings: SettingsStore) throws {
        self.settings = settings
        paused = try settings.bool(Self.pausedKey) ?? false
        let apps = try settings.string(Self.appsKey).flatMap(Self.decode) ?? []
        let patterns = try settings.string(Self.patternsKey).flatMap(Self.decode) ?? []
        currentRules = IgnoreRules(apps: Set(apps), patterns: patterns)
        compiled = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// In-memory control without persistence, for tests and previews.
    public init(paused: Bool = false, rules: IgnoreRules = IgnoreRules()) {
        settings = nil
        self.paused = paused
        currentRules = rules
        compiled = rules.patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    public var isPaused: Bool { lock.withLock { paused } }
    public var rules: IgnoreRules { lock.withLock { currentRules } }

    public func setPaused(_ value: Bool) throws {
        try settings?.set(value, for: Self.pausedKey)
        lock.withLock { paused = value }
    }

    /// Flips the pause state and returns the new one.
    @discardableResult
    public func togglePause() throws -> Bool {
        let next = !isPaused
        try setPaused(next)
        return next
    }

    public func addIgnoredApp(_ bundleID: String) throws {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255, !trimmed.contains(where: \.isWhitespace)
        else {
            throw CaptureControlError.invalidBundleID
        }
        var apps = rules.apps
        apps.insert(trimmed)
        try saveApps(apps)
    }

    public func removeIgnoredApp(_ bundleID: String) throws {
        var apps = rules.apps
        apps.remove(bundleID)
        try saveApps(apps)
    }

    public func addPattern(_ pattern: String) throws {
        guard pattern.count <= Self.maximumPatternLength else {
            throw CaptureControlError.patternTooLong
        }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw CaptureControlError.invalidPattern(pattern)
        }
        var patterns = rules.patterns
        if patterns.contains(pattern) { return }
        guard patterns.count < Self.maximumPatterns else {
            throw CaptureControlError.tooManyPatterns
        }
        patterns.append(pattern)
        try settings?.set(Self.encode(patterns), for: Self.patternsKey)
        lock.withLock {
            currentRules.patterns = patterns
            compiled.append(regex)
        }
    }

    public func removePattern(_ pattern: String) throws {
        var patterns = rules.patterns
        guard let index = patterns.firstIndex(of: pattern) else { return }
        patterns.remove(at: index)
        try settings?.set(Self.encode(patterns), for: Self.patternsKey)
        lock.withLock {
            currentRules.patterns = patterns
            compiled = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        }
    }

    /// True when a rule matches the content. A rule that needs more than `matchBudget` counts as
    /// matched, so a pattern that backtracks badly keeps the copy out instead of stalling capture.
    func matchesPattern(_ text: String) -> Bool {
        let expressions = lock.withLock { compiled }
        guard !expressions.isEmpty else { return false }
        let scanned = String(text.prefix(Self.maximumScannedCharacters))
        let range = NSRange(scanned.startIndex..., in: scanned)
        let deadline = Date().addingTimeInterval(Self.matchBudget)
        for expression in expressions {
            var found = false
            expression.enumerateMatches(in: scanned, options: [.reportProgress], range: range) {
                match, flags, stop in
                if match != nil {
                    found = true
                    stop.pointee = true
                } else if flags.contains(.progress), Date() > deadline {
                    found = true
                    stop.pointee = true
                }
            }
            if found { return true }
        }
        return false
    }

    private func saveApps(_ apps: Set<String>) throws {
        try settings?.set(Self.encode(apps.sorted()), for: Self.appsKey)
        lock.withLock { currentRules.apps = apps }
    }

    private static func encode(_ values: [String]) -> String {
        (try? JSONEncoder().encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func decode(_ text: String) -> [String]? {
        try? JSONDecoder().decode([String].self, from: Data(text.utf8))
    }
}

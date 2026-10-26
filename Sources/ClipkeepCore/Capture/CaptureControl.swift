import Foundation

public enum CaptureControlError: Error, Equatable {
    case invalidPattern(String)
    case patternTooLong
    case patternTooSlow
    case tooManyPatterns
    case invalidBundleID
    /// A stored setting could not be read back. Capture stays off instead of guessing.
    case corruptSetting(String)
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
///
/// Rules look at the first `maximumScannedCharacters` UTF-16 units of a copy only; later text is
/// not checked by them (the secret detector still sees all of it).
public final class CaptureControl: @unchecked Sendable {
    public static let maximumPatterns = 50
    public static let maximumPatternLength = 500
    /// Longest stretch of content a rule looks at, in UTF-16 units.
    static let maximumScannedCharacters = 20_000
    /// Time one pattern may spend on one copy before it counts as matched.
    static let patternBudget: Duration = .milliseconds(50)
    /// Time all patterns together may spend on one copy.
    static let totalBudget: Duration = .milliseconds(250)

    private static let pausedKey = "capture.paused"
    private static let appsKey = "capture.ignoredApps"
    private static let patternsKey = "capture.ignoredPatterns"
    private static let bundleIDCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    private let settings: SettingsStore?
    /// Serialises edits: read, save and publish happen as one step.
    private let mutationLock = NSLock()
    /// Guards the published state below.
    private let lock = NSLock()
    private var paused: Bool
    private var generation = 0
    private var currentRules: IgnoreRules
    private var compiled: [NSRegularExpression]

    /// Loads the saved state. A value that cannot be read throws, so capture does not start with
    /// rules or a pause state the user never chose.
    public init(settings: SettingsStore) throws {
        self.settings = settings
        switch try settings.string(Self.pausedKey) {
        case nil, "0": paused = false
        case "1": paused = true
        case .some: throw CaptureControlError.corruptSetting(Self.pausedKey)
        }
        let apps = try Self.load(Self.appsKey, from: settings)
        let patterns = try Self.load(Self.patternsKey, from: settings)
        var seen = Set<String>()
        let unique = patterns.filter { seen.insert($0).inserted }
        guard unique.count <= Self.maximumPatterns else {
            throw CaptureControlError.corruptSetting(Self.patternsKey)
        }
        currentRules = IgnoreRules(apps: Set(apps), patterns: unique)
        compiled = try unique.map {
            guard $0.count <= Self.maximumPatternLength,
                let regex = try? NSRegularExpression(pattern: $0)
            else { throw CaptureControlError.corruptSetting(Self.patternsKey) }
            return regex
        }
    }

    /// In-memory control without persistence, for tests and previews. Patterns that do not
    /// compile are ignored.
    public init(paused: Bool = false, rules: IgnoreRules = IgnoreRules()) {
        settings = nil
        self.paused = paused
        currentRules = rules
        compiled = rules.patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    public var isPaused: Bool { lock.withLock { paused } }
    public var rules: IgnoreRules { lock.withLock { currentRules } }

    /// Increases every time capture is paused, so a pause that was over again before the next
    /// poll is still noticed.
    public var pauseGeneration: Int { lock.withLock { generation } }

    /// Pausing takes effect first and is saved afterwards; if saving fails capture stays paused
    /// and the error is thrown. Resuming is saved first, so a failed save keeps capture paused.
    public func setPaused(_ value: Bool) throws {
        try mutationLock.withLock { try applyPause(value) }
    }

    /// Flips the pause state and returns the new one.
    @discardableResult
    public func togglePause() throws -> Bool {
        try mutationLock.withLock {
            let next = !isPaused
            try applyPause(next)
            return next
        }
    }

    private func applyPause(_ value: Bool) throws {
        if value {
            lock.withLock {
                paused = true
                generation += 1
            }
            try settings?.set(true, for: Self.pausedKey)
        } else {
            try settings?.set(false, for: Self.pausedKey)
            lock.withLock { paused = false }
        }
    }

    public func addIgnoredApp(_ bundleID: String) throws {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255,
            trimmed.unicodeScalars.allSatisfy(Self.bundleIDCharacters.contains)
        else { throw CaptureControlError.invalidBundleID }
        try mutationLock.withLock {
            var apps = rules.apps
            apps.insert(trimmed)
            try saveApps(apps)
        }
    }

    public func removeIgnoredApp(_ bundleID: String) throws {
        try mutationLock.withLock {
            var apps = rules.apps
            apps.remove(bundleID)
            try saveApps(apps)
        }
    }

    /// Adds a content rule. Patterns that are invalid, too long, or too slow on ordinary text
    /// are rejected.
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
        guard Self.samples.allSatisfy({ Self.matchResult(of: [regex], in: $0) != .timedOut }) else {
            throw CaptureControlError.patternTooSlow
        }
        try mutationLock.withLock {
            var patterns = rules.patterns
            if patterns.contains(pattern) { return }
            guard patterns.count < Self.maximumPatterns else {
                throw CaptureControlError.tooManyPatterns
            }
            patterns.append(pattern)
            try savePatterns(patterns)
        }
    }

    public func removePattern(_ pattern: String) throws {
        try mutationLock.withLock {
            let patterns = rules.patterns.filter { $0 != pattern }
            guard patterns.count != rules.patterns.count else { return }
            try savePatterns(patterns)
        }
    }

    /// True when a rule matches the content. A rule that needs more than its time budget counts
    /// as matched, so a pattern that backtracks badly keeps the copy out instead of stalling
    /// capture.
    func matchesPattern(_ text: String) -> Bool {
        let expressions = lock.withLock { compiled }
        guard !expressions.isEmpty else { return false }
        return Self.matchResult(of: expressions, in: text) != .noMatch
    }

    private enum MatchResult { case matched, timedOut, noMatch }

    private static func matchResult(of expressions: [NSRegularExpression], in text: String)
        -> MatchResult
    {
        let scanned = prefix(of: text)
        let range = NSRange(location: 0, length: (scanned as NSString).length)
        let clock = ContinuousClock()
        let totalDeadline = clock.now + totalBudget
        for expression in expressions {
            let deadline = min(clock.now + patternBudget, totalDeadline)
            var result = MatchResult.noMatch
            expression.enumerateMatches(in: scanned, options: [.reportProgress], range: range) {
                match, flags, stop in
                if match != nil {
                    result = .matched
                    stop.pointee = true
                } else if flags.contains(.progress), clock.now > deadline {
                    result = .timedOut
                    stop.pointee = true
                }
            }
            if result != .noMatch { return result }
            if clock.now > totalDeadline { return .timedOut }
        }
        return .noMatch
    }

    /// The first `maximumScannedCharacters` UTF-16 units, never cutting a character in half.
    private static func prefix(of text: String) -> String {
        let string = text as NSString
        guard string.length > maximumScannedCharacters else { return text }
        let last = string.rangeOfComposedCharacterSequence(at: maximumScannedCharacters - 1)
        return string.substring(to: NSMaxRange(last))
    }

    /// Texts a new pattern must handle within its budget: ordinary prose, and long runs that make
    /// nested quantifiers backtrack.
    private static let samples = [
        String(
            repeating:
                "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor ",
            count: 250),
        String(repeating: "a", count: 3_000) + "!",
        String(repeating: "ab ", count: 1_500) + "!",
    ]

    private func saveApps(_ apps: Set<String>) throws {
        try settings?.set(Self.encode(apps.sorted()), for: Self.appsKey)
        lock.withLock { currentRules.apps = apps }
    }

    private func savePatterns(_ patterns: [String]) throws {
        try settings?.set(Self.encode(patterns), for: Self.patternsKey)
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        lock.withLock {
            currentRules.patterns = patterns
            compiled = regexes
        }
    }

    private static func load(_ key: String, from settings: SettingsStore) throws -> [String] {
        guard let text = try settings.string(key) else { return [] }
        guard let values = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else {
            throw CaptureControlError.corruptSetting(key)
        }
        return values
    }

    private static func encode(_ values: [String]) -> String {
        (try? JSONEncoder().encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

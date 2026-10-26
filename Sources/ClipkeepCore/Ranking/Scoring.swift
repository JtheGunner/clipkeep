import Foundation

public enum Tier: String, Sendable, Equatable, CaseIterable {
    case hot
    case warm
    case archive
}

/// Tunable weights of the importance score. A weight of 0 switches a signal off.
public struct ScoringWeights: Sendable, Equatable {
    public var frecency: Double = 3
    public var frecencyHalfLifeDays: Double = 7
    public var repetition: Double = 1
    public var length: Double = 1
    public var pin: Double = 100
    /// Bonus for a starred item. Unlike a pin it still fades and can change tier.
    public var star: Double = 3
    /// Score per "more like this" (+) or "less like this" (-) step.
    public var feedback: Double = 1.5
    /// Score offset per content kind; kinds not listed count as 0.
    public var kinds: [ContentKind: Double] = [
        .command: 1, .code: 1, .stacktrace: 0.5, .url: 0.5, .path: 0.5, .json: 0.5,
        .email: 0.25, .number: -0.5,
    ]
    /// Score offset per source app (bundle identifier); unknown apps count as 0.
    public var apps: [String: Double] = [:]

    public init() {}
}

/// When an item moves between tiers and whether archived items ever expire.
public struct TierPolicy: Sendable, Equatable {
    public var hotDays: Double
    public var warmDays: Double
    /// Archived, unpinned items older than this many days are deleted. `nil` (the default)
    /// keeps everything forever: nothing is deleted unless the user opted in.
    public var archiveRetentionDays: Double?

    public init(hotDays: Double = 7, warmDays: Double = 60, archiveRetentionDays: Double? = nil) {
        self.hotDays = max(hotDays, 0)
        self.warmDays = max(warmDays, self.hotDays)
        // Never expire something that would still be warm.
        self.archiveRetentionDays = archiveRetentionDays.map { max($0, self.warmDays) }
    }
}

public struct ScoreInput: Sendable, Equatable {
    /// Copy times, newest first. Only the most recent ones are needed for frecency.
    public var copyDates: [Date]
    public var copyCount: Int
    public var kind: ContentKind
    public var characterCount: Int
    public var latestAppBundleID: String?
    public var isPinned: Bool
    public var isStarred: Bool
    /// Net "more/less like this" steps, see `ItemActions.feedbackLimit`.
    public var feedbackSteps: Int

    public init(
        copyDates: [Date], copyCount: Int, kind: ContentKind, characterCount: Int,
        latestAppBundleID: String? = nil, isPinned: Bool = false, isStarred: Bool = false,
        feedbackSteps: Int = 0
    ) {
        self.copyDates = copyDates
        self.copyCount = copyCount
        self.kind = kind
        self.characterCount = characterCount
        self.latestAppBundleID = latestAppBundleID
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.feedbackSteps = feedbackSteps
    }
}

public struct ScoreComponent: Sendable, Equatable {
    public let name: String
    public let value: Double
    /// Human-readable reason, for example "5 copies, newest 2.0 days ago".
    public let detail: String
}

public struct ScoreExplanation: Sendable, Equatable {
    public let components: [ScoreComponent]
    public let total: Double
    /// `total` squashed into 0...1, used as a ranking boost. Pinned items are always 1.
    public let importance: Double
    public let tier: Tier
}

public enum Scorer {
    static let maximumFrecency = 10.0
    private static let secondsPerDay = 86_400.0

    public static func explain(
        _ input: ScoreInput, weights: ScoringWeights = ScoringWeights(),
        policy: TierPolicy = TierPolicy(), now: Date = Date()
    ) -> ScoreExplanation {
        let newest = input.copyDates.max()
        let ageDays = newest.map { max(now.timeIntervalSince($0), 0) / secondsPerDay }

        let decay = frecencySum(
            input.copyDates, halfLifeDays: weights.frecencyHalfLifeDays, now: now)
        let band = lengthBand(input.characterCount)
        let appOffset = input.latestAppBundleID.flatMap { weights.apps[$0] } ?? 0
        let components = [
            ScoreComponent(
                name: "frecency", value: weights.frecency * min(decay, maximumFrecency),
                detail: ageDays.map {
                    String(format: "recent copies add up to %.2f, newest %.1f days ago", decay, $0)
                } ?? "no copies"),
            ScoreComponent(
                name: "repetition",
                value: weights.repetition * log2(Double(max(input.copyCount, 1))),
                detail: "\(input.copyCount) copies"),
            ScoreComponent(
                name: "kind", value: weights.kinds[input.kind] ?? 0, detail: input.kind.rawValue),
            ScoreComponent(
                name: "length", value: weights.length * band,
                detail: "\(input.characterCount) characters"),
            ScoreComponent(
                name: "app", value: appOffset, detail: input.latestAppBundleID ?? "unknown app"),
            ScoreComponent(
                name: "star", value: input.isStarred ? weights.star : 0,
                detail: input.isStarred ? "starred" : "not starred"),
            ScoreComponent(
                name: "feedback", value: weights.feedback * Double(input.feedbackSteps),
                detail: "\(input.feedbackSteps) net more/less-like-this steps"),
            ScoreComponent(
                name: "pin", value: input.isPinned ? weights.pin : 0,
                detail: input.isPinned ? "pinned" : "not pinned"),
        ]
        let total = components.reduce(0) { $0 + $1.value }
        let importance = input.isPinned ? 1 : 1 / (1 + exp(-(total - 2) / 2))
        return ScoreExplanation(
            components: components, total: total, importance: importance,
            tier: tier(
                lastCopyAgeDays: ageDays, isPinned: input.isPinned, policy: policy))
    }

    /// Sum of 0.5^(age / halfLife) over copies: each copy counts fully when new and fades out.
    static func frecencySum(_ dates: [Date], halfLifeDays: Double, now: Date) -> Double {
        guard halfLifeDays > 0 else { return 0 }
        return dates.reduce(0) { sum, date in
            let age = max(now.timeIntervalSince(date), 0) / secondsPerDay
            return sum + pow(0.5, age / halfLifeDays)
        }
    }

    /// Trapezoid in -1...1: tiny and enormous texts are penalised, typical snippets get the
    /// full bonus (20 up to 2 000 characters), with linear ramps in between.
    static func lengthBand(_ characters: Int) -> Double {
        let n = Double(characters)
        switch n {
        case ..<3: return -1
        case ..<20: return -1 + 2 * (n - 3) / 17
        case ...2_000: return 1
        case ..<100_000: return 1 - 2 * (n - 2_000) / 98_000
        default: return -1
        }
    }

    static func tier(lastCopyAgeDays: Double?, isPinned: Bool, policy: TierPolicy) -> Tier {
        guard !isPinned, let age = lastCopyAgeDays else { return .hot }
        if age <= policy.hotDays { return .hot }
        if age <= policy.warmDays { return .warm }
        return .archive
    }
}

import Foundation

/// How two stored contents relate. Both stay in the database; the link only records the relation.
public enum DuplicateKind: String, Sendable, Equatable {
    /// Same text apart from case and whitespace.
    case normalized
    /// Similar wording, found by SimHash within the configured distance.
    case near
}

public struct DuplicateLink: Sendable, Equatable {
    public let contentID: Int64
    public let relatedID: Int64
    public let kind: DuplicateKind
    /// Hamming distance for `.near`, 0 for `.normalized`.
    public let distance: Int
}

/// Tunable duplicate detection.
public struct DuplicateConfiguration: Sendable, Equatable {
    public static let `default` = DuplicateConfiguration()
    public static let maximumDistanceLimit = 8

    /// Largest SimHash Hamming distance (0...8) that still counts as a near-duplicate. A single
    /// changed word in a paragraph typically moves 2-9 of the 64 bits (about 80% stay within 8);
    /// unrelated texts differ in about 32, so 8 rarely links unrelated texts.
    public let maximumDistance: Int
    /// Upper bound of links stored per new content, closest first.
    public let maximumLinks: Int
    /// Most candidates compared per band for a new content. Many near-identical texts fill one
    /// band bucket, and comparing against all of them makes importing quadratic. Identical
    /// fingerprints are looked at first, then the newest, so the cap only matters in such
    /// crowded buckets.
    public static let candidateBudget = 2_000

    public init(maximumDistance: Int = 8, maximumLinks: Int = 5) {
        self.maximumDistance = min(max(maximumDistance, 0), Self.maximumDistanceLimit)
        self.maximumLinks = max(maximumLinks, 0)
    }
}

enum FingerprintBands {
    /// The 64 bits are cut into nine bands. Two fingerprints at most 8 bits apart differ in at
    /// most 8 bands, so they share at least one band exactly (pigeonhole) and a band lookup
    /// never misses a match. The layout is fixed so the threshold can change without reindexing.
    static let count = DuplicateConfiguration.maximumDistanceLimit + 1

    static func values(of fingerprint: UInt64) -> [Int64] {
        (0..<count).map { band in
            let lower = band * 64 / count
            let width = (band + 1) * 64 / count - lower
            return Int64((fingerprint >> UInt64(lower)) & ((1 << UInt64(width)) - 1))
        }
    }
}

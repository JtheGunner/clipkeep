import Foundation

/// How results without a text query are ordered.
public enum ListingOrder: Sendable, Equatable {
    /// Newest copy first.
    case recent
    /// Most important first (see `RankingService`), newest first among equals.
    case importance
}

/// Narrows a search. Every set field must hold for at least one copy event of an item.
public struct SearchFilter: Sendable, Equatable {
    public var appBundleID: String?
    public var copiedAfter: Date?
    public var copiedBefore: Date?
    public var sessionID: Int64?
    /// Only copies made in a session of this topic.
    public var topicID: Int64?
    public var kind: String?
    /// Leaves out this kind, for example parked-secret placeholders.
    public var excludedKind: String?
    public var limit: Int
    public var listingOrder: ListingOrder

    public init(
        appBundleID: String? = nil, copiedAfter: Date? = nil, copiedBefore: Date? = nil,
        sessionID: Int64? = nil, topicID: Int64? = nil, kind: String? = nil,
        excludedKind: String? = nil, limit: Int = 50,
        listingOrder: ListingOrder = .recent
    ) {
        self.appBundleID = appBundleID
        self.copiedAfter = copiedAfter
        self.copiedBefore = copiedBefore
        self.sessionID = sessionID
        self.topicID = topicID
        self.kind = kind
        self.excludedKind = excludedKind
        self.limit = limit
        self.listingOrder = listingOrder
    }
}

public struct SearchHit: Sendable, Equatable {
    public let contentID: Int64
    public let text: String
    public let kind: String
    public let lastCopiedAt: Date
    public let occurrenceCount: Int
    public let lastAppName: String?
    public let lastWindowTitle: String?
    public let lastURL: String?
    public var isPinned = false
    public var isStarred = false
}

public enum SecretKind: String, Sendable, Equatable {
    case openAIKey
    case anthropicKey
    case githubToken
    case awsAccessKeyID
    case slackToken
    case gitlabToken
    case stripeKey
    case googleAPIKey
    case jwt
    case privateKey
    case keyValueSecret
    case highEntropyToken
}

public enum SecretConfidence: Int, Sendable, Comparable {
    case medium
    case high

    public static func < (lhs: SecretConfidence, rhs: SecretConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Where a secret sits in the scanned text. It deliberately carries no copy of the value,
/// so logging or persisting a match can never leak the secret itself.
public struct SecretMatch: Sendable, Equatable {
    public let kind: SecretKind
    public let confidence: SecretConfidence
    public let range: Range<String.Index>

    public init(kind: SecretKind, confidence: SecretConfidence, range: Range<String.Index>) {
        self.kind = kind
        self.confidence = confidence
        self.range = range
    }
}

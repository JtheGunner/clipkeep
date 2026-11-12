import Foundation

/// Replaces every secret in a snippet with a placeholder named after its kind, so a stored
/// snippet stays readable (`DB_PASSWORD=<VALUE>`) without keeping the value anywhere.
public struct SnippetAnonymizer: Sendable {
    /// An identifier followed by `=` at the start of a high-entropy match. The detector's token
    /// pattern includes `=`, so `NAME=value` can arrive as one match; the name stays readable.
    private static let assignmentPrefix = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_]{0,63}="#)

    private let detector: SecretDetector

    public init(detector: SecretDetector = SecretDetector()) {
        self.detector = detector
    }

    public func anonymize(_ text: String) -> String {
        let matches = detector.detect(in: text)
        guard !matches.isEmpty else { return text }
        var result = text
        // Matches are ordered by position and do not overlap; replacing from the last one keeps
        // the earlier ranges valid.
        for match in matches.reversed() {
            let range = Self.replacedRange(of: match, in: text)
            result.replaceSubrange(range, with: Self.placeholder(for: match.kind))
        }
        return result
    }

    private static func replacedRange(of match: SecretMatch, in text: String)
        -> Range<String.Index>
    {
        guard match.kind == .highEntropyToken else { return match.range }
        let value = String(text[match.range])
        let whole = NSRange(value.startIndex..., in: value)
        guard let prefix = assignmentPrefix.firstMatch(in: value, range: whole),
            prefix.range.length < whole.length,
            let prefixRange = Range(prefix.range, in: value)
        else { return match.range }
        let nameLength = value.distance(from: value.startIndex, to: prefixRange.upperBound)
        let valueStart = text.index(match.range.lowerBound, offsetBy: nameLength)
        return valueStart..<match.range.upperBound
    }

    static func placeholder(for kind: SecretKind) -> String {
        switch kind {
        case .openAIKey: "<OPENAI_API_KEY>"
        case .anthropicKey: "<ANTHROPIC_API_KEY>"
        case .githubToken: "<GITHUB_TOKEN>"
        case .awsAccessKeyID: "<AWS_ACCESS_KEY_ID>"
        case .slackToken: "<SLACK_TOKEN>"
        case .gitlabToken: "<GITLAB_TOKEN>"
        case .stripeKey: "<STRIPE_KEY>"
        case .googleAPIKey: "<GOOGLE_API_KEY>"
        case .jwt: "<JWT>"
        case .privateKey: "<PRIVATE_KEY>"
        case .keyValueSecret: "<VALUE>"
        case .highEntropyToken: "<TOKEN>"
        }
    }
}

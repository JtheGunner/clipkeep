import Foundation

/// Replaces every secret in a snippet with a placeholder named after its kind, so a stored
/// snippet stays readable (`DB_PASSWORD=<VALUE>`) without keeping the value anywhere.
public struct SnippetAnonymizer: Sendable {
    /// The detector's token pattern includes `=`, so `NAME=value` can arrive as one
    /// high-entropy match. The name is kept only when it reads like a variable name: upper-case
    /// (`BUILD_SEED`) or lower-case snake case (`build_seed`). Anything else, such as the body of
    /// a base64 value with `==` padding, is redacted whole.
    private static let variableName = try! NSRegularExpression(
        pattern: #"^(?:[A-Z][A-Z0-9_]{0,63}|[a-z][a-z0-9]{0,31}(?:_[a-z0-9]{1,31}){0,7})$"#)
    /// The part after `NAME=` must be long enough to be the secret itself.
    private static let minimumAssignedValueLength = 16

    private let detector: SecretDetector

    public init(detector: SecretDetector = SecretDetector()) {
        self.detector = detector
    }

    public func anonymize(_ text: String) -> String {
        let matches = detector.detect(in: text)
        guard !matches.isEmpty else { return text }
        // Matches are ordered by position and do not overlap, so one forward pass over the
        // unchanged original text builds the result.
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            let range = Self.redactedRange(of: match, in: text)
            result += text[cursor..<range.lowerBound]
            result += Self.placeholder(for: match.kind)
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// The whole match, except that a plausible `NAME=` before a high-entropy value is kept.
    /// Every doubtful case redacts the whole match, so no part of a secret can stay readable.
    private static func redactedRange(of match: SecretMatch, in text: String)
        -> Range<String.Index>
    {
        guard match.kind == .highEntropyToken else { return match.range }
        let token = text[match.range]
        guard let equals = token.firstIndex(of: "=") else { return match.range }
        let name = String(token[..<equals])
        let value = token[token.index(after: equals)...]
        let isVariableName =
            variableName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        guard isVariableName, value.count >= minimumAssignedValueLength,
            value.contains(where: { $0 != "=" })
        else { return match.range }
        return value.startIndex..<match.range.upperBound
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

import Foundation

/// Finds credentials in copied text using known token formats, key/value hints and entropy.
/// Pure and deterministic: no I/O, no state.
public struct SecretDetector: Sendable {
    private struct Rule: Sendable {
        let kind: SecretKind
        let confidence: SecretConfidence
        let pattern: String
        /// Capture group holding the secret; 0 means the whole match.
        let group: Int
    }

    // Order matters: the first rule claiming a range wins, so specific prefixes come before
    // the generic ones (sk-ant- before sk-).
    private static let rules: [Rule] = [
        Rule(
            kind: .privateKey, confidence: .high,
            pattern: "-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----", group: 0),
        Rule(
            kind: .anthropicKey, confidence: .high, pattern: "sk-ant-[A-Za-z0-9_\\-]{20,}", group: 0
        ),
        Rule(
            kind: .openAIKey, confidence: .high,
            pattern: "sk-(?:proj-|svcacct-)?[A-Za-z0-9_\\-]{20,}", group: 0),
        Rule(
            kind: .githubToken, confidence: .high, pattern: "\\bgh[pousr]_[A-Za-z0-9]{36,}\\b",
            group: 0),
        Rule(
            kind: .githubToken, confidence: .high, pattern: "\\bgithub_pat_[A-Za-z0-9_]{22,}",
            group: 0),
        Rule(
            kind: .awsAccessKeyID, confidence: .high, pattern: "\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b",
            group: 0),
        Rule(
            kind: .slackToken, confidence: .high, pattern: "\\bxox[abprs]-[A-Za-z0-9\\-]{10,}",
            group: 0),
        Rule(
            kind: .gitlabToken, confidence: .high, pattern: "\\bglpat-[A-Za-z0-9_\\-]{20,}",
            group: 0),
        Rule(
            kind: .stripeKey, confidence: .high, pattern: "\\b[sr]k_live_[A-Za-z0-9]{16,}", group: 0
        ),
        Rule(
            kind: .googleAPIKey, confidence: .high, pattern: "\\bAIza[0-9A-Za-z_\\-]{35}\\b",
            group: 0),
        Rule(
            kind: .jwt, confidence: .high,
            pattern: "\\beyJ[A-Za-z0-9_\\-]{8,}\\.eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}",
            group: 0),
        Rule(
            kind: .keyValueSecret, confidence: .medium,
            pattern:
                "(?i)\\b(?:api[_-]?key|secret|token|passwd|password|authorization)\\b[\"']?\\s*[:=]\\s*[\"']?(?:bearer\\s+)?([^\\s\"',;]{8,})",
            group: 1),
    ]

    private static let compiled: [(Rule, NSRegularExpression)] = rules.map {
        // The patterns are constants covered by tests, so a failure is a programmer error.
        ($0, try! NSRegularExpression(pattern: $0.pattern))
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9_+=\\-]{30,}")
    private static let uuidPattern = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")
    private static let hashLengths: Set<Int> = [32, 40, 56, 64, 96, 128]

    /// Minimum Shannon entropy in bits per character for an unknown token.
    private let entropyThreshold: Double
    private let allowedHashes: Set<String>

    /// - Parameter allowedHashes: `ContentHashing.exactHash` of matched values the user marked as
    ///   "not a secret". Hashes are stored instead of the values themselves.
    public init(entropyThreshold: Double = 4.0, allowedHashes: Set<String> = []) {
        self.entropyThreshold = entropyThreshold
        self.allowedHashes = allowedHashes
    }

    /// All secrets found in `text`, ordered by position. Overlapping findings keep the first rule.
    public func detect(in text: String) -> [SecretMatch] {
        let whole = NSRange(text.startIndex..., in: text)
        var matches: [SecretMatch] = []

        for (rule, regex) in Self.compiled {
            for result in regex.matches(in: text, range: whole) {
                let nsRange = result.range(at: rule.group)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else {
                    continue
                }
                if rule.kind == .keyValueSecret, !Self.looksLikeSecretValue(text[range]) {
                    continue
                }
                append(
                    SecretMatch(kind: rule.kind, confidence: rule.confidence, range: range),
                    text: text, to: &matches)
            }
        }

        for result in Self.tokenPattern.matches(in: text, range: whole) {
            guard let range = Range(result.range, in: text) else { continue }
            let token = text[range]
            guard isHighEntropySecret(token) else { continue }
            append(
                SecretMatch(kind: .highEntropyToken, confidence: .medium, range: range),
                text: text, to: &matches)
        }

        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    public func containsSecret(in text: String) -> Bool {
        !detect(in: text).isEmpty
    }

    private func append(_ match: SecretMatch, text: String, to matches: inout [SecretMatch]) {
        guard !matches.contains(where: { $0.range.overlaps(match.range) }) else { return }
        guard !allowedHashes.contains(ContentHashing.exactHash(String(text[match.range]))) else {
            return
        }
        matches.append(match)
    }

    private func isHighEntropySecret(_ token: Substring) -> Bool {
        let value = String(token)
        guard !Self.isHashOrIdentifier(value) else { return false }
        let hasDigit = value.contains(where: \.isNumber)
        let hasLetter = value.contains(where: \.isLetter)
        guard hasDigit, hasLetter else { return false }
        return Self.shannonEntropy(value) >= entropyThreshold
    }

    /// Hex digests (MD5, SHA-1/224/256/384/512), commit IDs and UUIDs are random-looking but harmless.
    private static func isHashOrIdentifier(_ value: String) -> Bool {
        let isHex = value.allSatisfy(\.isHexDigit)
        if isHex, hashLengths.contains(value.count) || value.count >= 40 { return true }
        let range = NSRange(value.startIndex..., in: value)
        return uuidPattern.firstMatch(in: value, range: range) != nil
    }

    /// A key/value hint only counts when the value is not obviously a placeholder or a word.
    private static func looksLikeSecretValue(_ value: Substring) -> Bool {
        let lowered = value.lowercased()
        let placeholders = [
            "password", "changeme", "example", "your_", "<", "${", "{{", "null", "none",
        ]
        if placeholders.contains(where: lowered.hasPrefix) { return false }
        return value.contains(where: \.isNumber) || value.contains(where: \.isUppercase)
            || value.count >= 12
    }

    static func shannonEntropy(_ value: String) -> Double {
        let counts = value.reduce(into: [Character: Int]()) { $0[$1, default: 0] += 1 }
        let length = Double(value.count)
        return counts.values.reduce(0) { sum, count in
            let probability = Double(count) / length
            return sum - probability * log2(probability)
        }
    }
}

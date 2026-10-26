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

    /// Prefix rules must not start inside a longer word ("task-scheduler-…" is not an sk- key).
    private static let boundary = #"(?<![A-Za-z0-9_\-])"#

    // Order matters: the first rule claiming a range wins, so specific prefixes come before
    // the generic ones (sk-ant- before sk-). Quantifiers are capped so one huge token-like run
    // cannot exhaust ICU's backtracking stack and silently end the scan.
    private static let rules: [Rule] = [
        Rule(
            kind: .privateKey, confidence: .high,
            pattern:
                #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----(?:[\s\S]{0,16384}?-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----)?"#,
            group: 0),
        Rule(
            kind: .anthropicKey, confidence: .high,
            pattern: boundary + #"sk-ant-[A-Za-z0-9_\-]{20,512}"#, group: 0),
        Rule(
            kind: .openAIKey, confidence: .high,
            pattern: boundary
                + #"sk-(?=[A-Za-z0-9_\-]*\d)(?:proj-|svcacct-)?[A-Za-z0-9_\-]{20,512}"#,
            group: 0),
        Rule(
            kind: .githubToken, confidence: .high,
            pattern: boundary + #"gh[pousr]_[A-Za-z0-9]{36,255}"#, group: 0),
        Rule(
            kind: .githubToken, confidence: .high,
            pattern: boundary + #"github_pat_[A-Za-z0-9_]{22,255}"#, group: 0),
        Rule(
            kind: .awsAccessKeyID, confidence: .high,
            pattern: boundary + #"(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"#, group: 0),
        Rule(
            kind: .slackToken, confidence: .high,
            pattern: boundary + #"xox[abprs]-[A-Za-z0-9\-]{10,255}"#, group: 0),
        Rule(
            kind: .slackToken, confidence: .high,
            pattern:
                #"https://hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]{20,64}"#,
            group: 0),
        Rule(
            kind: .gitlabToken, confidence: .high,
            pattern: boundary + #"glpat-[A-Za-z0-9_\-]{20,255}"#, group: 0),
        Rule(
            kind: .stripeKey, confidence: .high,
            pattern: boundary + #"[sr]k_live_[A-Za-z0-9]{16,255}"#, group: 0),
        Rule(
            kind: .googleAPIKey, confidence: .high,
            pattern: boundary + #"AIza[0-9A-Za-z_\-]{35}(?![A-Za-z0-9_])"#, group: 0),
        Rule(
            kind: .jwt, confidence: .high,
            pattern:
                boundary
                + #"eyJ[A-Za-z0-9_\-]{8,4096}\.eyJ[A-Za-z0-9_\-]{8,4096}\.[A-Za-z0-9_\-]{8,4096}"#,
            group: 0),
        // The name may carry a prefix or suffix (DB_PASSWORD, aws_secret_access_key) because the start is
        // anchored at the beginning of an identifier-like run, which keeps the scan linear.
        Rule(
            kind: .keyValueSecret, confidence: .medium,
            pattern:
                #"(?i)(?<![A-Za-z0-9_\-.])[A-Za-z0-9_\-.]{0,64}?(?:api[_-]?key|secret|token|passw(?:or)?d|passwort|kennwort|authorization|credentials?)[A-Za-z0-9_\-.]{0,32}["']?\s{0,8}[:=]\s{0,8}["']?(?:(?:bearer|basic|token)\s{1,4})?([^\s"',;]{8,512})"#,
            group: 1),
    ]

    private static let compiled: [(Rule, NSRegularExpression)] = rules.map {
        // The patterns are constants covered by tests, so a failure is a programmer error.
        ($0, try! NSRegularExpression(pattern: $0.pattern))
    }

    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9_+=/\-]{30,4096}"#)
    private static let uuidPattern = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$"#)
    private static let integrityPrefix = try! NSRegularExpression(pattern: #"^sha\d{1,3}-"#)
    private static let identifierLike = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_.]*$"#)
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

    private struct Claim {
        let range: Range<String.Index>
        /// `nil` for ranges the user allowed: they still block wider overlapping matches.
        let match: SecretMatch?
    }

    /// All secrets found in `text`, ordered by position. Overlapping findings keep the first rule.
    public func detect(in text: String) -> [SecretMatch] {
        let whole = NSRange(text.startIndex..., in: text)
        var claims: [Claim] = []

        for (rule, regex) in Self.compiled {
            var found: [Claim] = []
            for result in regex.matches(in: text, range: whole) {
                let nsRange = result.range(at: rule.group)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else {
                    continue
                }
                if rule.kind == .keyValueSecret, !Self.looksLikeSecretValue(text[range]) {
                    continue
                }
                found.append(
                    claim(kind: rule.kind, confidence: rule.confidence, range: range, in: text))
            }
            claims = Self.merge(claims, adding: found)
        }

        var tokens: [Claim] = []
        for result in Self.tokenPattern.matches(in: text, range: whole) {
            guard let range = Range(result.range, in: text),
                isHighEntropySecret(text[range], before: text[..<range.lowerBound])
            else { continue }
            tokens.append(
                claim(kind: .highEntropyToken, confidence: .medium, range: range, in: text))
        }
        claims = Self.merge(claims, adding: tokens)

        return claims.compactMap(\.match)
    }

    public func containsSecret(in text: String) -> Bool {
        !detect(in: text).isEmpty
    }

    private func claim(
        kind: SecretKind, confidence: SecretConfidence, range: Range<String.Index>, in text: String
    ) -> Claim {
        let allowed = allowedHashes.contains(ContentHashing.exactHash(String(text[range])))
        return Claim(
            range: range,
            match: allowed ? nil : SecretMatch(kind: kind, confidence: confidence, range: range))
    }

    /// Merges two position-sorted lists in linear time, dropping new claims that overlap an
    /// existing one. Both inputs are sorted and internally non-overlapping.
    private static func merge(_ existing: [Claim], adding new: [Claim]) -> [Claim] {
        guard !new.isEmpty else { return existing }
        var merged: [Claim] = []
        merged.reserveCapacity(existing.count + new.count)
        var i = 0
        for candidate in new {
            while i < existing.count, existing[i].range.upperBound <= candidate.range.lowerBound {
                merged.append(existing[i])
                i += 1
            }
            var j = i
            var overlaps = false
            while j < existing.count, existing[j].range.lowerBound < candidate.range.upperBound {
                overlaps = true
                j += 1
            }
            if !overlaps { merged.append(candidate) }
        }
        merged.append(contentsOf: existing[i...])
        return merged.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func isHighEntropySecret(_ token: Substring, before: Substring) -> Bool {
        let value = String(token)
        guard !value.hasPrefix("/"), !before.hasSuffix("base64,") else { return false }
        let range = NSRange(value.startIndex..., in: value)
        guard Self.integrityPrefix.firstMatch(in: value, range: range) == nil else { return false }
        guard !Self.isHashOrIdentifier(value), !Self.isSlug(value) else { return false }
        guard value.contains(where: \.isNumber), value.contains(where: \.isLetter) else {
            return false
        }
        return Self.shannonEntropy(value) >= entropyThreshold
    }

    /// Hex digests (MD5, SHA-1/224/256/384/512), commit IDs and UUIDs are random-looking but
    /// harmless, also when they follow a short label ("build-<sha1>", "Linux-node-<sha256>").
    private static func isHashOrIdentifier(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        if uuidPattern.firstMatch(in: value, range: range) != nil { return true }
        let segments = value.split(whereSeparator: { $0 == "-" || $0 == "_" })
        let hashes = segments.filter { isHexDigest($0) }
        guard !hashes.isEmpty else { return false }
        return segments.filter { !isHexDigest($0) }.allSatisfy { $0.count <= 12 }
    }

    private static func isHexDigest(_ segment: Substring) -> Bool {
        segment.allSatisfy(\.isHexDigit)
            && (hashLengths.contains(segment.count) || segment.count >= 40)
    }

    /// Many short, mostly alphabetic segments read like a URL slug or branch name, not a key.
    private static func isSlug(_ value: String) -> Bool {
        let segments = value.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "/" })
        guard segments.count >= 4, segments.allSatisfy({ $0.count <= 14 }) else { return false }
        let wordLike = segments.filter { $0.allSatisfy(\.isLetter) }.count
        return Double(wordLike) / Double(segments.count) >= 0.7
    }

    /// A key/value hint only counts when the value is not a placeholder, a call or an identifier.
    private static func looksLikeSecretValue(_ value: Substring) -> Bool {
        let lowered = value.lowercased()
        let placeholders = [
            "password", "changeme", "example", "your_", "<", "${", "{{", "null", "none",
        ]
        if placeholders.contains(where: lowered.hasPrefix) { return false }
        if value.contains("(") || value.contains(")") { return false }
        let text = String(value)
        let isIdentifier =
            identifierLike.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        if isIdentifier, !value.contains(where: \.isNumber) { return false }
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

import Testing

@testable import ClipkeepCore

/// Fixtures are assembled at runtime so no secret-shaped literal sits in the repository.
private enum Fixture {
    /// Deterministic pseudo-random characters (fixed-seed LCG), so failures are reproducible.
    static func chars(_ alphabet: String, _ count: Int) -> String {
        let characters = Array(alphabet)
        var state: UInt32 = 2_463_534_242
        return String(
            (0..<count).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return characters[Int(state >> 16) % characters.count]
            })
    }

    static let alnum = "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz"
    static let anthropic = "sk-" + "ant-" + "api03-" + chars(alnum + "_-", 40)
    static let openAI = "sk-" + "proj-" + chars(alnum, 40)
    static let github = "gh" + "p_" + chars(alnum, 36)
    static let githubFineGrained = "github" + "_pat_" + chars(alnum + "_", 40)
    static let aws = "AK" + "IA" + chars("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", 16)
    static let slack = "xo" + "xb-" + chars("0123456789", 12) + "-" + chars(alnum, 24)
    static let gitlab = "gl" + "pat-" + chars(alnum + "_-", 24)
    static let stripe = "sk" + "_live_" + chars(alnum, 24)
    static let google = "AI" + "za" + chars(alnum + "_-", 35)
    static let jwt =
        "ey" + "J" + chars(alnum, 12) + ".ey" + "J" + chars(alnum, 16) + "." + chars(alnum, 20)
    static let privateKeyHeader = "-----BEGIN " + "RSA PRIVATE KEY-----"
}

@Suite struct SecretDetectorTests {
    private let detector = SecretDetector()

    private func kinds(_ text: String) -> [SecretKind] {
        detector.detect(in: text).map(\.kind)
    }

    @Test func recognizesKnownTokenFormats() {
        #expect(kinds(Fixture.anthropic) == [.anthropicKey])
        #expect(kinds(Fixture.openAI) == [.openAIKey])
        #expect(kinds(Fixture.github) == [.githubToken])
        #expect(kinds(Fixture.githubFineGrained) == [.githubToken])
        #expect(kinds(Fixture.aws) == [.awsAccessKeyID])
        #expect(kinds(Fixture.slack) == [.slackToken])
        #expect(kinds(Fixture.gitlab) == [.gitlabToken])
        #expect(kinds(Fixture.stripe) == [.stripeKey])
        #expect(kinds(Fixture.google) == [.googleAPIKey])
        #expect(kinds(Fixture.jwt) == [.jwt])
        #expect(kinds(Fixture.privateKeyHeader) == [.privateKey])
    }

    @Test func anthropicKeyIsNotReportedAsOpenAI() {
        #expect(kinds(Fixture.anthropic) == [.anthropicKey])
    }

    @Test func findsSecretInsideLargerText() {
        let text = "export OPENAI_API_KEY=\(Fixture.openAI)\nrun it now"
        let matches = detector.detect(in: text)

        #expect(matches.count == 1)
        #expect(matches.first.map { String(text[$0.range]) } == Fixture.openAI)
    }

    @Test func recognizesKeyValueSecrets() {
        #expect(kinds("password: Tr0ub4dor&3xyz") == [.keyValueSecret])
        #expect(kinds("Authorization: Bearer abc123DEF456ghi789") == [.keyValueSecret])
        #expect(kinds("{\"api_key\": \"a1b2c3d4e5f6g7h8\"}") == [.keyValueSecret])
    }

    @Test func ignoresPlaceholderKeyValues() {
        #expect(kinds("password: changeme") == [])
        #expect(kinds("token=${GITHUB_TOKEN}") == [])
        #expect(kinds("api_key: <your key>") == [])
    }

    @Test func flagsUnknownHighEntropyTokens() {
        let token = Fixture.chars(Fixture.alnum + "-_", 48)
        #expect(kinds("deploy with \(token) now") == [.highEntropyToken])
    }

    @Test func doesNotFlagHexDigestsCommitsOrUUIDs() {
        #expect(kinds("a94a8fe5ccb19ba61c4c0873d391e987982fbbd3") == [])
        #expect(kinds("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == [])
        #expect(kinds("d41d8cd98f00b204e9800998ecf8427e") == [])
        #expect(kinds("550e8400-e29b-41d4-a716-446655440000") == [])
    }

    @Test func doesNotFlagOrdinaryText() {
        #expect(kinds("Hello world, this is a normal sentence about clipboards.") == [])
        #expect(kinds("getUserDataFromRepositoryAndCacheLayer") == [])
        #expect(kinds("/Users/jeffry/Projects/clipkeep/Sources/ClipkeepCore/Storage") == [])
        #expect(kinds("https://example.com/docs/getting-started/installation-guide") == [])
        #expect(kinds("") == [])
    }

    @Test func shortTokensAreIgnored() {
        #expect(kinds("sk-short") == [])
        #expect(kinds("ghp_tooShort") == [])
    }

    @Test func allowedHashSuppressesAMatch() {
        let allowing = SecretDetector(allowedHashes: [ContentHashing.exactHash(Fixture.github)])

        #expect(allowing.detect(in: "token \(Fixture.github)").isEmpty)
        #expect(!allowing.detect(in: "token \(Fixture.openAI)").isEmpty)
    }

    @Test func findsSeveralSecretsInOrder() {
        let text = "\(Fixture.aws) and later \(Fixture.github)"
        #expect(kinds(text) == [.awsAccessKeyID, .githubToken])
    }

    @Test func matchesNeverContainTheSecretValue() {
        let text = "x \(Fixture.github)"
        let match = detector.detect(in: text).first

        #expect(match != nil)
        #expect(!String(describing: match!).contains(Fixture.github))
    }

    @Test func entropyOfUniformStringIsZero() {
        #expect(SecretDetector.shannonEntropy("aaaaaaaa") == 0)
        #expect(SecretDetector.shannonEntropy("abcdabcd") == 2)
    }
}

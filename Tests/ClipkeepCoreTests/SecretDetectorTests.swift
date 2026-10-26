import Foundation
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

@Suite struct SecretDetectorReviewTests {
    private let detector = SecretDetector()

    private func kinds(_ text: String, using detector: SecretDetector? = nil) -> [SecretKind] {
        (detector ?? self.detector).detect(in: text).map(\.kind)
    }

    @Test func kebabCaseWordsEndingInSkAreNotKeys() {
        #expect(kinds("disk-utilization-dashboard-panel") == [])
        #expect(kinds("run the task-scheduler-for-nightly-builds now") == [])
        #expect(kinds(".mask-image-linear-gradient-overlay") == [])
    }

    @Test func envFilesWithSnakeCaseNamesAreDetected() {
        #expect(kinds("DB_PASSWORD=Xk9#mP2$vLq!7z") == [.keyValueSecret])
        #expect(kinds("client_secret=Xk9#mP2$vLq!7z") == [.keyValueSecret])
        #expect(kinds("GITHUB_TOKEN=Ab3#de5$Fg7!hj9") == [.keyValueSecret])
        #expect(kinds("{\"access_token\": \"Ab3#de5$Fg7!hj9\"}") == [.keyValueSecret])
        #expect(kinds("aws_secret_access_key=Xk9#mP2$vLq!7z") == [.keyValueSecret])
    }

    @Test func basicAuthAndGermanKeywordsAreDetected() {
        #expect(kinds("Authorization: Basic dXNlcjpwYXNzd29yZA==") == [.keyValueSecret])
        #expect(kinds("Passwort: Xk9#mP2$vLq!7z") == [.keyValueSecret])
    }

    @Test func codeAssignmentsAreNotSecrets() {
        #expect(kinds("let secret = KeychainSecretStore()") == [])
        #expect(kinds("token = request.headers.get(\"Authorization\")") == [])
        #expect(kinds("api_key = settings.OPENAI_API_KEY") == [])
    }

    @Test func labelledHashesAndIntegrityStringsAreNotSecrets() {
        #expect(kinds("build-a94a8fe5ccb19ba61c4c0873d391e987982fbbd3") == [])
        #expect(
            kinds("Linux-node-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
                == [])
        let integrity = "sha512-" + Fixture.chars(Fixture.alnum + "+/", 86) + "=="
        #expect(kinds("\"integrity\": \"\(integrity)\"") == [])
        #expect(kinds("how-to-configure-nginx-reverse-proxy-on-ubuntu-22-04") == [])
    }

    @Test func base64DataURIsAreNotFlagged() {
        let payload = Fixture.chars(Fixture.alnum + "+/", 120)
        #expect(kinds("data:image/png;base64,\(payload)") == [])
    }

    @Test func awsSecretAccessKeysWithSlashAreDetected() {
        let key = Fixture.chars(Fixture.alnum + "+/", 40)
        #expect(!kinds("secret \(key) end").isEmpty)
    }

    @Test func allowedValueStaysAllowedInsideAWiderAssignment() {
        let allowing = SecretDetector(allowedHashes: [ContentHashing.exactHash(Fixture.openAI)])
        #expect(kinds("export OPENAI_API_KEY=\(Fixture.openAI)", using: allowing) == [])
    }

    @Test func pemBlockIsCoveredFromHeaderToFooter() {
        let body = Fixture.chars(Fixture.alnum, 64)
        let pem =
            "-----BEGIN "
            + "PGP PRIVATE KEY BLOCK-----\n\(body)\n-----END PGP PRIVATE KEY BLOCK-----"
        let matches = detector.detect(in: pem)

        #expect(matches.count == 1)
        #expect(matches.first.map { String(pem[$0.range]) } == pem)
    }

    @Test func googleKeyEndingInDashIsStillAGoogleKey() {
        let key = "AI" + "za" + Fixture.chars(Fixture.alnum, 34) + "-"
        #expect(kinds("key \(key) end") == [.googleAPIKey])
    }

    @Test func slackWebhookIsDetected() {
        let hook =
            "https://hooks.slack" + ".com/services/T" + Fixture.chars("ABCDEFG123", 8)
            + "/B" + Fixture.chars("ABCDEFG123", 9) + "/" + Fixture.chars(Fixture.alnum, 24)
        #expect(kinds(hook) == [.slackToken])
    }

    @Test func secretAfterAHugeTokenRunIsStillFound() {
        let run = String(repeating: "deadbeef", count: 100_000)  // 800 kB without whitespace
        let text = run + "\nexport OPENAI_API_KEY=" + Fixture.openAI

        #expect(kinds(text).contains(.openAIKey))
    }

    @Test func manyMatchesFinishQuickly() {
        let token = Fixture.chars(Fixture.alnum + "-_", 32)
        let text = Array(repeating: token, count: 20_000).joined(separator: " ")
        let started = Date()

        _ = detector.detect(in: text)

        #expect(Date().timeIntervalSince(started) < PerformanceBudget.limit(5))
    }
}

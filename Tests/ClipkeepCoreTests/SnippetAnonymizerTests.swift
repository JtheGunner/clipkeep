import Foundation
import Testing

@testable import ClipkeepCore

/// Fake credentials are assembled at runtime so no secret-shaped literal sits in the repository.
private enum FakeSecret {
    /// Deterministic pseudo-random characters (fixed-seed LCG), so failures are reproducible.
    static func chars(
        _ count: Int, seed: UInt32 = 2_463_534_242,
        alphabet: String = "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz"
    ) -> String {
        let characters = Array(alphabet)
        var state = seed
        return String(
            (0..<count).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return characters[Int(state >> 16) % characters.count]
            })
    }

    static let anthropic = "sk-" + "ant-" + "api03-" + chars(30)
    static let github = "gh" + "p_" + chars(36, seed: 7)
    static let entropyToken = "Zq7" + chars(37, seed: 99)
    /// A base64 value with `==` padding: an alphanumeric body that starts with a letter.
    static let paddedBody = "Kx" + chars(40, seed: 4242)
    static let openAI = "sk-" + "proj-" + chars(40, seed: 11)
    static let aws = "AK" + "IA" + chars(16, seed: 12, alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    static let slack =
        "xo" + "xb-" + chars(12, seed: 13, alphabet: "0123456789") + "-" + chars(24, seed: 14)
    static let gitlab = "gl" + "pat-" + chars(24, seed: 15)
    static let stripe = "sk" + "_live_" + chars(24, seed: 16)
    static let google = "AI" + "za" + chars(35, seed: 17)
    static let jwt =
        "ey" + "J" + chars(12, seed: 18) + ".ey" + "J" + chars(16, seed: 19) + "."
        + chars(20, seed: 20)
    static let privateKeyBlock =
        "-----BEGIN " + "RSA PRIVATE KEY-----\n" + chars(64, seed: 21) + "\n"
        + chars(64, seed: 22) + "\n-----END " + "RSA PRIVATE KEY-----"
    static let keyValue = "password: " + "Tr0ub4dor" + chars(6, seed: 23)

    /// One sample per placeholder kind, each embedded in a small command.
    static let samplesOfEveryKind: [String] = [
        "export OPENAI_API_KEY=\(openAI)",
        "curl -H 'x-key: \(anthropic)' api",
        "gh auth login --with-token \(github)",
        "aws configure set aws_access_key_id \(aws)",
        "curl -H 'Authorization: \(slack)'",
        "glab auth login --token \(gitlab)",
        "stripe login --api-key \(stripe)",
        "gcloud config set api_key \(google)",
        "curl -H 'X-Auth: \(jwt)'",
        privateKeyBlock,
        "db \(keyValue)",
        "deploy \(entropyToken)",
    ]
}

@Suite struct SnippetAnonymizerTests {
    private let anonymizer = SnippetAnonymizer()

    @Test func redactsAPaddedBase64ValueCompletely() {
        let value = FakeSecret.paddedBody + "=="
        let result = anonymizer.anonymize("echo \(value) | base64 -d")

        #expect(result == "echo <TOKEN> | base64 -d")
        #expect(!result.contains(FakeSecret.paddedBody.prefix(8)))
        #expect(!result.contains(FakeSecret.paddedBody.suffix(8)))
    }

    @Test func redactsAPaddedValueAfterAVariableName() {
        let result = anonymizer.anonymize("export BUILD_SEED=\(FakeSecret.paddedBody)==")

        #expect(result == "export BUILD_SEED=<TOKEN>")
    }

    @Test func redactsTheWholeMatchWhenTheNameDoesNotReadLikeAVariable() {
        let text = "x MixedCase9=\(FakeSecret.entropyToken)"

        #expect(anonymizer.anonymize(text) == "x <TOKEN>")
    }

    @Test(arguments: FakeSecret.samplesOfEveryKind)
    func anonymisingIsIdempotentAndLeavesNoSecret(sample: String) {
        let once = anonymizer.anonymize(sample)

        #expect(once != sample)
        #expect(anonymizer.anonymize(once) == once)
        #expect(SecretDetector().detect(in: once).isEmpty)
    }

    @Test func emptyTextStaysEmpty() {
        #expect(anonymizer.anonymize("") == "")
    }

    @Test func multiByteTextAroundASecretIsKept() {
        let text = "Grüße 🚀 \(FakeSecret.github) — Größe ✅"

        #expect(anonymizer.anonymize(text) == "Grüße 🚀 <GITHUB_TOKEN> — Größe ✅")
    }

    @Test func adjacentSecretsAreBothReplaced() {
        let text = "\(FakeSecret.github) \(FakeSecret.anthropic)\n\(FakeSecret.openAI)"

        #expect(
            anonymizer.anonymize(text) == "<GITHUB_TOKEN> <ANTHROPIC_API_KEY>\n<OPENAI_API_KEY>")
    }

    @Test func multiLinePrivateKeyBlockIsReplacedWhole() {
        let text = "cat > key.pem <<EOF\n\(FakeSecret.privateKeyBlock)\nEOF"

        #expect(anonymizer.anonymize(text) == "cat > key.pem <<EOF\n<PRIVATE_KEY>\nEOF")
    }

    @Test func replacesKeyValueValueOnly() {
        #expect(
            anonymizer.anonymize("export DB_PASSWORD=hunter2hunter2")
                == "export DB_PASSWORD=<VALUE>")
    }

    @Test func replacesKnownTokenFormats() {
        let anthropic = anonymizer.anonymize("curl -H 'x-key: \(FakeSecret.anthropic)' api")
        let github = anonymizer.anonymize("gh auth login --with-token \(FakeSecret.github)")

        #expect(anthropic.contains("<ANTHROPIC_API_KEY>"))
        #expect(!anthropic.contains(FakeSecret.anthropic))
        #expect(github == "gh auth login --with-token <GITHUB_TOKEN>")
        #expect(!github.contains(FakeSecret.github))
    }

    @Test func replacesSeveralSecretsWithoutShiftingRanges() {
        let text = "use \(FakeSecret.github) and then | grep x | \(FakeSecret.anthropic) done"

        #expect(
            anonymizer.anonymize(text)
                == "use <GITHUB_TOKEN> and then | grep x | <ANTHROPIC_API_KEY> done")
    }

    @Test func keepsTheVariableNameOfAHighEntropyAssignment() {
        let text = "export BUILD_SEED=\(FakeSecret.entropyToken)"

        #expect(anonymizer.anonymize(text) == "export BUILD_SEED=<TOKEN>")
    }

    @Test func replacesALooseHighEntropyToken() {
        #expect(anonymizer.anonymize("deploy \(FakeSecret.entropyToken)") == "deploy <TOKEN>")
    }

    @Test func leavesHashesUuidsAndPathsAlone() {
        let checkout =
            "git checkout 3f786850e387550fdab836ed7e265a98c0ffee12 -- /usr/local/etc/some/very/long/path/file.conf"
        let uuid = "xcrun simctl boot 6F9619FF-8B86-D011-B42D-00C04FC964FF"

        #expect(anonymizer.anonymize(checkout) == checkout)
        #expect(anonymizer.anonymize(uuid) == uuid)
    }

    @Test func textWithoutSecretsIsReturnedUnchanged() {
        let text = "kubectl get pods -n prod | grep Crash\nkubectl delete pod web-1 -n prod"

        #expect(anonymizer.anonymize(text) == text)
    }

    @Test func respectsValuesTheUserAllowed() {
        let allowed = SnippetAnonymizer(
            detector: SecretDetector(allowedHashes: [ContentHashing.exactHash("hunter2hunter2")]))

        #expect(
            allowed.anonymize("export DB_PASSWORD=hunter2hunter2")
                == "export DB_PASSWORD=hunter2hunter2")
    }
}

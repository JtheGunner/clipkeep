import Foundation
import Testing

@testable import ClipkeepCore

/// Fake credentials are assembled at runtime so no secret-shaped literal sits in the repository.
private enum FakeSecret {
    /// Deterministic pseudo-random characters (fixed-seed LCG), so failures are reproducible.
    static func chars(_ count: Int, seed: UInt32 = 2_463_534_242) -> String {
        let characters = Array("aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz")
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
}

@Suite struct SnippetAnonymizerTests {
    private let anonymizer = SnippetAnonymizer()

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

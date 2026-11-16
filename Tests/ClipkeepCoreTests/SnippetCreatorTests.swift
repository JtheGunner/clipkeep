import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetCreatorTests {
    private static let secretShell = "DB_PASSWORD=hunter2hunter2 ./scripts/test.sh --filter Core"

    private struct Fixture {
        let temp: TemporaryDatabase
        let snippets: SnippetStore
        let creator: SnippetCreator

        init(anonymizer: SnippetAnonymizer = SnippetAnonymizer()) throws {
            temp = try TemporaryDatabase()
            let database = try temp.open()
            snippets = SnippetStore(database: database)
            creator = SnippetCreator(store: snippets, anonymizer: anonymizer)
        }

        func only() throws -> Snippet {
            let all = try snippets.list(limit: 10)
            try #require(all.count == 1)
            return all[0]
        }
    }

    @Test func createStoresAManualSnippet() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }

        let outcome = try fixture.creator.create(
            text: "SELECT 1;", language: .sql, comment: "smoke test")

        let stored = try fixture.only()
        #expect(outcome == .created(stored.id))
        #expect(stored.origin == .manual)
        #expect(stored.language == .sql)
        #expect(stored.comment == "smoke test")
    }

    @Test func createAnonymisesSecrets() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        // Assembled at runtime so no secret-shaped literal sits in the repository.
        let token = "gh" + "p_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYzaB3"

        let outcome = try fixture.creator.create(
            text: "curl -H 'Authorization: token \(token)' https://example.com/api",
            language: .shell, comment: nil)

        guard case .created = outcome else {
            Issue.record("expected created, got \(outcome)")
            return
        }
        #expect(!(try fixture.only().text.contains(token)))
        #expect(try fixture.snippets.search(token, limit: 10).isEmpty)
    }

    @Test(arguments: ["", "   ", "\n\t  \n"])
    func emptyAndWhitespaceTextIsRefused(text: String) throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }

        #expect(try fixture.creator.create(text: text, language: .shell, comment: nil) == .empty)
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func oversizeTextIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let big = String(repeating: "a", count: SnippetFilter.Threshold.maximumBytes + 1)
        let huge = String(repeating: "a", count: SnippetCapture.maximumSourceBytes + 1)

        #expect(try fixture.creator.create(text: big, language: .shell, comment: nil) == .tooLarge)
        #expect(try fixture.creator.create(text: huge, language: .shell, comment: nil) == .tooLarge)
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func residualSecretIsRefused() throws {
        // An anonymiser that lets the value through simulates a redaction that missed a secret.
        let lenient = SnippetAnonymizer(
            detector: SecretDetector(allowedHashes: [ContentHashing.exactHash("hunter2hunter2")]))
        let fixture = try Fixture(anonymizer: lenient)
        defer { fixture.temp.remove() }

        #expect(
            try fixture.creator.create(text: Self.secretShell, language: .shell, comment: nil)
                == .residualSecret)
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func joiningAnExistingShapeReportsJoined() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let added = try fixture.snippets.add(
            text: "ls -la /a/", language: .shell, origin: .auto, appName: nil)
        guard case .inserted(let id) = added else {
            Issue.record("expected an inserted snippet")
            return
        }

        let outcome = try fixture.creator.create(
            text: "ls -la /b/", language: .shell, comment: "listing")

        #expect(outcome == .joined(id))
        let joined = try fixture.only()
        #expect(joined.variantCount == 2)
        #expect(joined.origin == .manual)
        #expect(joined.comment == "listing")

        _ = try fixture.creator.create(text: "ls -la /c/", language: .shell, comment: "other")
        #expect(try fixture.only().comment == "listing")
    }

    @Test func createClearsARejection() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let added = try fixture.snippets.add(
            text: "SELECT 1;", language: .sql, origin: .auto, appName: nil)
        guard case .inserted(let id) = added else {
            Issue.record("expected an inserted snippet")
            return
        }
        _ = try fixture.snippets.delete(id: id)

        let outcome = try fixture.creator.create(text: "SELECT 1;", language: .sql, comment: nil)

        guard case .created = outcome else {
            Issue.record("expected created, got \(outcome)")
            return
        }
    }

    @Test func guessLanguageUsesTheFilterAndDefaultsToShell() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }

        #expect(
            fixture.creator.guessLanguage("SELECT id, name FROM customers WHERE active = 1;")
                == .sql)
        #expect(fixture.creator.guessLanguage("hello there") == .shell)
    }
}

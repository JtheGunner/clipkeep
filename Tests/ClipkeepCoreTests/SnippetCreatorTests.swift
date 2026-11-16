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

        #expect(outcome == .joined(id, commentKept: false))
        let joined = try fixture.only()
        #expect(joined.variantCount == 2)
        #expect(joined.origin == .manual)
        #expect(joined.comment == "listing")

        #expect(
            try fixture.creator.create(text: "ls -la /c/", language: .shell, comment: "other")
                == .joined(id, commentKept: true))
        #expect(try fixture.only().comment == "listing")
        // Nothing typed, or the same comment again, keeps nothing back from the user.
        #expect(
            try fixture.creator.create(text: "ls -la /d/", language: .shell, comment: " ")
                == .joined(id, commentKept: false))
        #expect(
            try fixture.creator.create(text: "ls -la /e/", language: .shell, comment: "listing")
                == .joined(id, commentKept: false))
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

    // MARK: - Comments

    private static func githubToken() -> String {
        // Assembled at runtime so no secret-shaped literal sits in the repository.
        "gh" + "p_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYzaB3"
    }

    private func insertedSnippet(_ fixture: Fixture) throws -> Int64 {
        guard
            case .inserted(let id) = try fixture.snippets.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil)
        else { throw CreatorTestError.notInserted }
        return id
    }

    @Test func commentSecretsAreReplacedByPlaceholders() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedSnippet(fixture)
        let token = Self.githubToken()

        #expect(try fixture.creator.setComment(id: id, comment: "uses \(token) here") == .saved)

        let comment = try #require(try fixture.only().comment)
        #expect(comment == "uses <GITHUB_TOKEN> here")
        #expect(!(try fixture.only().searchText.contains(token.lowercased())))
        #expect(try fixture.snippets.search(token, limit: 10).isEmpty)
    }

    @Test func commentWithAResidualSecretIsRefusedAndTheOldOneKept() throws {
        let lenient = SnippetAnonymizer(
            detector: SecretDetector(allowedHashes: [ContentHashing.exactHash("hunter2hunter2")]))
        let fixture = try Fixture(anonymizer: lenient)
        defer { fixture.temp.remove() }
        let id = try insertedSnippet(fixture)
        #expect(try fixture.creator.setComment(id: id, comment: "before") == .saved)

        #expect(
            try fixture.creator.setComment(id: id, comment: "DB_PASSWORD=hunter2hunter2")
                == .residualSecret)

        #expect(try fixture.only().comment == "before")
        #expect(try fixture.snippets.search("hunter2", limit: 10).isEmpty)
    }

    @Test func plainCommentsAreStoredUnchangedAndCanBeCleared() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedSnippet(fixture)
        let plain = "Räumt /tmp auf, siehe Ticket 42 – nur nachts ausführen!"

        #expect(try fixture.creator.setComment(id: id, comment: "  \(plain) \n") == .saved)
        #expect(try fixture.only().comment == plain)
        #expect(try fixture.creator.setComment(id: id, comment: "   ") == .cleared)
        #expect(try fixture.only().comment == nil)
        #expect(try fixture.creator.setComment(id: id, comment: "again") == .saved)
        #expect(try fixture.creator.setComment(id: id, comment: nil) == .cleared)
        #expect(try fixture.only().comment == nil)
    }

    @Test func commentCapStillApplies() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedSnippet(fixture)

        #expect(
            try fixture.creator.setComment(id: id, comment: String(repeating: "x", count: 5000))
                == .saved)

        #expect(try fixture.only().comment?.count == 2000)
    }

    @Test func commentOnAMissingSnippetReportsNotFound() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedSnippet(fixture)
        _ = try fixture.snippets.delete(id: id)

        #expect(try fixture.creator.setComment(id: id, comment: "late") == .notFound)
    }

    @Test func createAnonymisesTheComment() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let token = Self.githubToken()

        let outcome = try fixture.creator.create(
            text: "ls -la /a/", language: .shell, comment: "token \(token)")

        #expect(outcome == .created(try fixture.only().id))
        #expect(try fixture.only().comment == "token <GITHUB_TOKEN>")
    }

    @Test func createWithAResidualSecretInTheCommentStoresNothing() throws {
        let lenient = SnippetAnonymizer(
            detector: SecretDetector(allowedHashes: [ContentHashing.exactHash("hunter2hunter2")]))
        let fixture = try Fixture(anonymizer: lenient)
        defer { fixture.temp.remove() }

        #expect(
            try fixture.creator.create(
                text: "ls -la /a/", language: .shell, comment: "DB_PASSWORD=hunter2hunter2")
                == .commentResidualSecret)
        #expect(try fixture.snippets.count() == 0)
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

private enum CreatorTestError: Error {
    case notInserted
}

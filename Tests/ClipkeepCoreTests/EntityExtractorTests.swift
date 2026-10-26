import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct EntityExtractorTests {
    private func entities(_ text: String, _ kind: EntityKind) -> [String] {
        EntityExtractor.extract(from: text).filter { $0.kind == kind }.map(\.value)
    }

    @Test func extractsDomainsAndRepos() {
        let text = "see https://www.GitHub.com/groue/GRDB.swift/issues/1 and https://example.org/x"

        #expect(entities(text, .domain) == ["github.com", "example.org"])
        #expect(entities(text, .repo) == ["github.com/groue/GRDB.swift"])
    }

    @Test func extractsEmailsWithTheirDomain() {
        let text = "write to Jeff.W@Example.com today"

        #expect(entities(text, .email) == ["jeff.w@example.com"])
        #expect(entities(text, .domain) == ["example.com"])
    }

    @Test func extractsTicketIDsButNotTechnicalNames() {
        let text = "Fixes CLIPK-12 and ABC-7; uses UTF-8, SHA-256, ISO-8601 and Nr-2"

        #expect(entities(text, .ticket) == ["CLIPK-12", "ABC-7"])
    }

    @Test func extractsFilePathsButNotURLPaths() {
        let text = "edit /Users/jeff/app/main.swift and ~/notes/todo.md via https://x.com/a/b/c"

        #expect(entities(text, .path) == ["/Users/jeff/app/main.swift", "~/notes/todo.md"])
    }

    @Test func extractsIdentifiers() {
        let text = "call getUserData then load_user_data and UserProfileView; plain words stay out"

        #expect(
            entities(text, .identifier) == ["getUserData", "load_user_data", "UserProfileView"])
    }

    @Test func deduplicatesAndCaps() {
        let repeated = String(repeating: "CLIPK-1 ", count: 100)
        let many = (0..<200).map { "TASK-\($0)" }.joined(separator: " ")

        #expect(entities(repeated, .ticket) == ["CLIPK-1"])
        #expect(EntityExtractor.extract(from: many).count == EntityExtractor.maximumEntities)
    }

    @Test func plainTextHasNoEntities() {
        #expect(EntityExtractor.extract(from: "Hello world, nothing to see.").isEmpty)
        #expect(EntityExtractor.extract(from: "").isEmpty)
    }

    @Test func typicalItemsAreAnalysedWithinMilliseconds() {
        let text = String(
            repeating: "see https://github.com/a/b and getUserData in /tmp/x/y for ABC-12\n",
            count: 50)
        let started = Date()

        for _ in 0..<20 { _ = EntityExtractor.extract(from: text) }

        let perItem = Date().timeIntervalSince(started) / 20
        #expect(perItem < 0.005, "took \(perItem * 1000) ms per item")
    }

    @Test func hugePastesOnlyCostTheAnalysedPrefix() {
        let text = String(repeating: "x", count: 5_000_000) + " CLIPK-9"
        let started = Date()

        let entities = EntityExtractor.extract(from: text)

        #expect(entities.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

@Suite struct IdentifierSplitterTests {
    @Test(arguments: [
        ("getUserData", ["get", "user", "data"]),
        ("get_user_data", ["get", "user", "data"]),
        ("UserProfileView", ["user", "profile", "view"]),
        ("URLParser", ["url", "parser"]),
        ("parseHTTPResponse", ["parse", "http", "response"]),
        ("kebab-case-name", ["kebab", "case", "name"]),
        ("sha256Hash", ["sha256", "hash"]),
        ("", []),
        ("word", ["word"]),
    ])
    func splitsIdentifiers(identifier: String, expected: [String]) {
        #expect(IdentifierSplitter.words(identifier) == expected)
    }
}

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
        #expect(entities(text, .repo) == ["github.com/groue/grdb.swift"])
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

@Suite struct EntityExtractorReviewTests {
    private func entities(_ text: String, _ kind: EntityKind) -> [String] {
        EntityExtractor.extract(from: text).filter { $0.kind == kind }.map(\.value)
    }

    @Test func gitSuffixIsOnlyRemovedFromTheEnd() {
        #expect(
            entities("https://github.com/foo/foo.github.io", .repo) == [
                "github.com/foo/foo.github.io"
            ])
        #expect(
            entities("git clone https://github.com/foo/bar.git", .repo) == ["github.com/foo/bar"])
    }

    @Test func repoNamesIgnoreTrailingPunctuationCaseAndNonRepoPages() {
        #expect(entities("see https://github.com/Foo/Bar.", .repo) == ["github.com/foo/bar"])
        #expect(entities("https://github.com/foo/bar/issues/12", .repo) == ["github.com/foo/bar"])
        #expect(entities("https://github.com/orgs/acme/people", .repo).isEmpty)
        #expect(entities("https://github.com/settings/profile", .repo).isEmpty)
        #expect(
            entities("https://gitlab.com/group/sub/repo/-/issues/3", .repo)
                == ["gitlab.com/group/sub/repo"])
    }

    @Test func urlCredentialsAndRemotesAreNotEmails() {
        #expect(entities("postgres://admin:hunter2@db.example.com:5432/app", .email).isEmpty)
        #expect(entities("https://user:pw@example.com/x", .email).isEmpty)
        #expect(entities("git clone git@github.com:foo/bar.git", .email).isEmpty)
        #expect(
            entities("postgres://admin:hunter2@db.example.com:5432/app", .domain) == [
                "db.example.com"
            ])
        #expect(
            !EntityExtractor.extract(from: "postgres://admin:hunter2@db.example.com/app")
                .contains { $0.value.contains("hunter2") })
    }

    @Test func standardsAndYearsAreNotTickets() {
        let text = "COVID-19 ES-2022 PEP-8 RFC-1234 WCAG-2 and CLIPK-3 plus AB-1999"

        #expect(entities(text, .ticket) == ["CLIPK-3"])
    }

    @Test func ticketsInsideURLsAreKept() {
        #expect(entities("https://jira.example.com/browse/ABC-12", .ticket) == ["ABC-12"])
    }

    @Test func pathsWithSpacesStayWhole() {
        #expect(
            entities("path /Users/jeff/My Documents/file.txt now", .path)
                == ["/Users/jeff/My Documents/file.txt"])
        #expect(
            entities("~/Library/Application Support/Clipkeep/db", .path)
                == ["~/Library/Application Support/Clipkeep/db"])
        #expect(entities("edit /tmp/x/y and /var/z/w later", .path) == ["/tmp/x/y", "/var/z/w"])
    }

    @Test func brandNamesAreNotIdentifiers() {
        #expect(
            entities("I use JavaScript on my iPhone and getUserData", .identifier) == [
                "getUserData"
            ])
    }

    @Test func theAnalysisCutNeverLeavesAHalfToken() {
        let filler = String(repeating: "word ", count: 13_106)  // the URL straddles the 64 KB cut
        let text = filler + "https://example.com/page"

        #expect(!EntityExtractor.extract(from: text).contains { $0.value.hasPrefix("exa") })
    }

    @Test func combiningMarksCannotDefeatTheCap() {
        let text = "a" + String(repeating: "\u{0301}", count: 2_500_000) + " CLIPK-9"
        let started = Date()

        _ = EntityExtractor.extract(from: text)

        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}

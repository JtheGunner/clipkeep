import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetExplorerTests {
    private static let day: TimeInterval = 86_400

    private static func snippet(
        _ id: Int64, _ text: String, _ language: SnippetLanguage, created: Double = 0,
        used: Double = 0, count: Int = 1
    ) -> Snippet {
        Snippet(
            id: id, text: text, language: language, origin: .auto, appName: nil,
            createdAt: Date(timeIntervalSince1970: created * day),
            lastCopiedAt: Date(timeIntervalSince1970: used * day), copyCount: count)
    }

    private let docker = snippet(
        1, "docker compose up -d", .shell, created: 1, used: 5, count: 3)
    private let git = snippet(2, "git log --oneline | head", .shell, created: 3, used: 2, count: 9)
    private let customers = snippet(
        3, "SELECT id FROM customers WHERE active", .sql, created: 2, used: 9, count: 1)
    private let compose = snippet(
        4, "services:\n  web:\n    image: nginx\n", .yaml, created: 4, used: 1, count: 5)

    private var all: [Snippet] { [docker, git, customers, compose] }

    private func ids(_ snippets: [Snippet]) -> [Int64] { snippets.map(\.id) }

    @Test func defaultOrderIsLastUsedNewestFirst() {
        let result = SnippetExplorer.apply(SnippetExplorerQuery(), to: all)
        #expect(ids(result) == [3, 1, 2, 4])
    }

    @Test func sortsByMostUsed() {
        let query = SnippetExplorerQuery(sortKey: .count)
        #expect(ids(SnippetExplorer.apply(query, to: all)) == [2, 4, 1, 3])
    }

    @Test func sortsByCreationDateAndReverses() {
        var query = SnippetExplorerQuery(sortKey: .created)
        #expect(ids(SnippetExplorer.apply(query, to: all)) == [4, 2, 3, 1])
        query.ascending = true
        #expect(ids(SnippetExplorer.apply(query, to: all)) == [1, 3, 2, 4])
    }

    @Test func sortsByLanguageThenRecency() {
        let query = SnippetExplorerQuery(sortKey: .language, ascending: true)
        // Shell, SQL, YAML; within shell the more recently used first.
        #expect(ids(SnippetExplorer.apply(query, to: all)) == [1, 2, 3, 4])
    }

    @Test func sortsByTopicWithMissingTopicsLast() {
        let anonymous = Self.snippet(5, "$(true)", .shell, used: 7)
        let query = SnippetExplorerQuery(sortKey: .topic, ascending: true)
        let result = SnippetExplorer.apply(query, to: all + [anonymous])
        // customers, docker, git, services, then the snippet without a topic.
        #expect(ids(result) == [3, 1, 2, 4, 5])
    }

    @Test func filtersByLanguage() {
        let query = SnippetExplorerQuery(language: .shell)
        #expect(Set(ids(SnippetExplorer.apply(query, to: all))) == [1, 2])
    }

    @Test func filtersByTopic() {
        let query = SnippetExplorerQuery(topic: "customers")
        #expect(ids(SnippetExplorer.apply(query, to: all)) == [3])
    }

    @Test func filtersByTextCaseInsensitivelyWithAllTermsRequired() {
        #expect(
            ids(SnippetExplorer.apply(SnippetExplorerQuery(text: "COMPOSE up"), to: all)) == [1])
        #expect(SnippetExplorer.apply(SnippetExplorerQuery(text: "docker nginx"), to: all).isEmpty)
    }

    @Test func textFilterAlsoMatchesTheTopic() {
        // "services" is the topic of the compose file and appears in its text; "kubectl" nowhere.
        #expect(ids(SnippetExplorer.apply(SnippetExplorerQuery(text: "services"), to: all)) == [4])
        #expect(SnippetExplorer.apply(SnippetExplorerQuery(text: "kubectl"), to: all).isEmpty)
    }

    @Test func combinesFilters() {
        let query = SnippetExplorerQuery(text: "git", language: .shell, topic: "git")
        #expect(ids(SnippetExplorer.apply(query, to: all)) == [2])
        let none = SnippetExplorerQuery(language: .sql, topic: "git")
        #expect(SnippetExplorer.apply(none, to: all).isEmpty)
    }

    @Test func listsTopicsWithCountsMostFrequentFirst() {
        let more = Self.snippet(6, "git status -sb", .shell)
        let topics = SnippetExplorer.topics(in: all + [more], language: nil)
        #expect(topics.first == SnippetTopicCount(name: "git", count: 2))
        #expect(Set(topics.map(\.name)) == ["git", "docker", "customers", "services"])
        // Ties by name.
        #expect(topics.dropFirst().map(\.name) == ["customers", "docker", "services"])
    }

    @Test func topicListFollowsTheLanguageFilter() {
        let topics = SnippetExplorer.topics(in: all, language: .shell)
        #expect(Set(topics.map(\.name)) == ["docker", "git"])
    }

    @Test func ignoresSnippetsWithoutATopicInTheTopicList() {
        let anonymous = Self.snippet(5, "$(true)", .shell)
        #expect(SnippetExplorer.topics(in: [anonymous], language: nil).isEmpty)
    }
}

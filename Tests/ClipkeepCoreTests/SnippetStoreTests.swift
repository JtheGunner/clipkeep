import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetStoreTests {
    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let store: SnippetStore

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = SnippetStore(database: database)
        }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func insertedID(_ outcome: SnippetAddOutcome) throws -> Int64 {
        guard case .inserted(let id) = outcome else {
            throw SnippetTestError.unexpectedOutcome("\(outcome)")
        }
        return id
    }

    @Test func addInsertsAndListReturnsNewestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "ls -la /tmp", language: .shell, origin: .auto, appName: "Terminal", at: base)
        _ = try fixture.store.add(
            text: "SELECT 1 FROM dual", language: .sql, origin: .history, appName: nil,
            at: base.addingTimeInterval(60))

        let snippets = try fixture.store.list(limit: 10)

        #expect(snippets.map(\.text) == ["SELECT 1 FROM dual", "ls -la /tmp"])
        #expect(snippets[0].language == .sql)
        #expect(snippets[0].origin == .history)
        #expect(snippets[0].appName == nil)
        #expect(snippets[1].appName == "Terminal")
        #expect(snippets[1].copyCount == 1)
    }

    @Test func addingTheSameTextBumpsInsteadOfDuplicating() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let first = try fixture.store.add(
            text: "ls -la", language: .shell, origin: .auto, appName: nil, at: base)
        let later = base.addingTimeInterval(120)
        let second = try fixture.store.add(
            text: "ls -la", language: .shell, origin: .auto, appName: nil, at: later)

        let id = try insertedID(first)
        #expect(second == .bumped(id))
        #expect(try fixture.store.count() == 1)
        let snippet = try #require(try fixture.store.list(limit: 10).first)
        #expect(snippet.copyCount == 2)
        #expect(snippet.lastCopiedAt == later)
        #expect(snippet.createdAt == base)
    }

    @Test func deleteRemovesAndRemembersTheText() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la", language: .shell, origin: .auto, appName: nil, at: base))

        #expect(try fixture.store.delete(id: id))
        #expect(try fixture.store.count() == 0)
        #expect(try fixture.store.delete(id: id) == false)
        #expect(
            try fixture.store.add(
                text: "ls -la", language: .shell, origin: .auto, appName: nil, at: base)
                == .rejected)
        #expect(try fixture.store.count() == 0)
    }

    @Test func overridingARejectionStoresAgain() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la", language: .shell, origin: .auto, appName: nil, at: base))
        _ = try fixture.store.delete(id: id)

        let outcome = try fixture.store.add(
            text: "ls -la", language: .shell, origin: .history, appName: nil,
            overridingRejection: true, at: base)

        guard case .inserted = outcome else {
            Issue.record("Expected inserted, got \(outcome)")
            return
        }
        #expect(try fixture.store.count() == 1)
        // The rejection is cleared, so a plain add now bumps.
        let again = try fixture.store.add(
            text: "ls -la", language: .shell, origin: .auto, appName: nil, at: base)
        guard case .bumped = again else {
            Issue.record("Expected bumped, got \(again)")
            return
        }
    }

    @Test func searchFindsByTrigramAndShortTerms() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "SELECT * FROM orders", language: .sql, origin: .auto, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "kubectl get pods", language: .shell, origin: .auto, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "echo über alles", language: .shell, origin: .auto, appName: nil, at: base)

        #expect(
            try fixture.store.search("orders", limit: 5).map(\.text) == ["SELECT * FROM orders"])
        #expect(try fixture.store.search("ku", limit: 5).map(\.text) == ["kubectl get pods"])
        #expect(try fixture.store.search("ÜBER", limit: 5).map(\.text) == ["echo über alles"])
        #expect(try fixture.store.search("nothing-here", limit: 5).isEmpty)
        #expect(try fixture.store.search("   ", limit: 5).count == 3)
    }

    @Test func searchOrdersByRelevanceThenCopyCountThenRecency() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        // Relevance: the shorter document matches the same term with better BM25.
        _ = try fixture.store.add(
            text: "pods and many other unrelated words around it here",
            language: .shell, origin: .auto, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "pods", language: .shell, origin: .auto, appName: nil, at: base)
        #expect(
            try fixture.store.search("pods", limit: 5).map(\.text)
                == ["pods", "pods and many other unrelated words around it here"])

        // Equal relevance: copy count decides, then recency.
        _ = try fixture.store.add(
            text: "alpha aaa", language: .shell, origin: .auto, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "alpha bbb", language: .shell, origin: .auto, appName: nil,
            at: base.addingTimeInterval(10))
        _ = try fixture.store.add(
            text: "alpha ccc", language: .shell, origin: .auto, appName: nil,
            at: base.addingTimeInterval(20))
        _ = try fixture.store.add(
            text: "alpha aaa", language: .shell, origin: .auto, appName: nil,
            at: base.addingTimeInterval(5))

        #expect(
            try fixture.store.search("alpha", limit: 5).map(\.text)
                == ["alpha aaa", "alpha ccc", "alpha bbb"])
    }

    @Test func searchRespectsTheLimit() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for index in 0..<3 {
            _ = try fixture.store.add(
                text: "echo item\(index)", language: .shell, origin: .auto, appName: nil,
                at: base.addingTimeInterval(Double(index)))
        }

        #expect(try fixture.store.search("echo", limit: 2).count == 2)
        #expect(try fixture.store.list(limit: 0).isEmpty)
    }

    @Test func maintenanceLeavesSnippetsAlone() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "ls -la", language: .shell, origin: .auto, appName: nil, at: base)

        _ = MaintenanceService(database: fixture.database).run(
            now: base.addingTimeInterval(3 * 365 * 86_400))

        #expect(try fixture.store.count() == 1)
    }

    @Test func migrationCreatesTables() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }

        let names = try fixture.database.read { connection in
            try connection.query(
                "SELECT name FROM sqlite_master WHERE name IN (?, ?, ?)",
                [.text("snippets"), .text("snippets_fts"), .text("snippet_rejections")]
            ) { $0.text(0) }
        }

        #expect(Set(names) == ["snippets", "snippets_fts", "snippet_rejections"])
    }
}

private enum SnippetTestError: Error {
    case unexpectedOutcome(String)
}

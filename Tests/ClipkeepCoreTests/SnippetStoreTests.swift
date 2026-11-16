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

    @Test func addWithoutBumpingLeavesAnExistingSnippetAlone() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la", language: .shell, origin: .auto, appName: nil, at: base))

        let again = try fixture.store.add(
            text: "ls -la", language: .shell, origin: .history, appName: nil,
            bumpingExisting: false, at: base.addingTimeInterval(120))

        #expect(again == .unchanged(id))
        let snippet = try #require(try fixture.store.list(limit: 10).first)
        #expect(snippet.copyCount == 1)
        #expect(snippet.lastCopiedAt == base)
        #expect(snippet.origin == .auto)
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

    @Test func sameShapeAddsAVariantNotASnippet() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: "Terminal",
                at: base))
        let later = base.addingTimeInterval(60)

        let second = try fixture.store.add(
            text: "ls -la /b/", language: .shell, origin: .auto, appName: "iTerm2", at: later)

        #expect(second == .bumped(id))
        #expect(try fixture.store.count() == 1)
        let snippets = try fixture.store.list(limit: 10)
        #expect(snippets.count == 1)
        let snippet = try #require(snippets.first)
        #expect(snippet.id == id)
        #expect(snippet.variantCount == 2)
        #expect(snippet.copyCount == 2)
        #expect(snippet.text == "ls -la /b/")
        #expect(snippet.appName == "iTerm2")
        #expect(snippet.createdAt == base)
        #expect(snippet.lastCopiedAt == later)
        #expect(snippet.shapeHash == SnippetShape.hash(of: "ls -la /a/", language: .shell))
        let variants = try fixture.store.variants(of: id)
        #expect(variants.map(\.text) == ["ls -la /b/", "ls -la /a/"])
        #expect(variants.allSatisfy { $0.snippetID == id && $0.copyCount == 1 })
        #expect(variants.map(\.lastCopiedAt) == [later, base])
    }

    @Test func sameTextBumpsTheVariant() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))

        let again = try fixture.store.add(
            text: "ls -la /a/", language: .shell, origin: .auto, appName: nil,
            at: base.addingTimeInterval(30))

        #expect(again == .bumped(id))
        let variants = try fixture.store.variants(of: id)
        #expect(variants.count == 1)
        #expect(variants.first?.copyCount == 2)
        #expect(variants.first?.lastCopiedAt == base.addingTimeInterval(30))
        #expect(try fixture.store.list(limit: 10).first?.variantCount == 1)
    }

    @Test func redirectVariantJoinsTheSnippet() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let texts = [
            "ls -la ~/Library/Caches/spotty/ 2>/dev/null",
            "ls -la ~/Library/Caches/spotty/plugin/",
            "ls -la ~/Library/Caches/spotty/prefs/",
        ]
        for (offset, text) in texts.enumerated() {
            _ = try fixture.store.add(
                text: text, language: .shell, origin: .auto, appName: nil,
                at: base.addingTimeInterval(Double(offset)))
        }

        #expect(try fixture.store.count() == 1)
        let snippet = try #require(try fixture.store.list(limit: 10).first)
        #expect(snippet.variantCount == 3)
        #expect(snippet.copyCount == 3)
        #expect(Set(try fixture.store.variants(of: snippet.id).map(\.text)) == Set(texts))
    }

    @Test func unchangedWhenNotBumping() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))

        let known = try fixture.store.add(
            text: "ls -la /a/", language: .shell, origin: .history, appName: nil,
            bumpingExisting: false, at: base.addingTimeInterval(10))
        #expect(known == .unchanged(id))
        #expect(try fixture.store.variants(of: id).map(\.copyCount) == [1])
        #expect(try fixture.store.list(limit: 10).first?.copyCount == 1)

        let newVariant = try fixture.store.add(
            text: "ls -la /b/", language: .shell, origin: .history, appName: nil,
            bumpingExisting: false, at: base.addingTimeInterval(20))
        #expect(newVariant == .unchanged(id))
        #expect(try fixture.store.count() == 1)
        let snippet = try #require(try fixture.store.list(limit: 10).first)
        #expect(snippet.variantCount == 2)
        #expect(snippet.copyCount == 1)
        #expect(snippet.origin == .auto)
    }

    @Test func deleteRejectsEveryVariant() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))
        _ = try fixture.store.add(
            text: "ls -la /b/", language: .shell, origin: .auto, appName: nil, at: base)

        #expect(try fixture.store.delete(id: id))
        #expect(try fixture.store.count() == 0)
        #expect(try fixture.store.variants(of: id).isEmpty)
        for text in ["ls -la /a/", "ls -la /b/"] {
            #expect(
                try fixture.store.add(
                    text: text, language: .shell, origin: .auto, appName: nil, at: base)
                    == .rejected)
        }
        #expect(try fixture.store.count() == 0)

        _ = try insertedID(
            try fixture.store.add(
                text: "ls -la /b/", language: .shell, origin: .manual, appName: nil,
                overridingRejection: true, at: base))
        #expect(try fixture.store.count() == 1)
    }

    @Test func manualAddRaisesOrigin() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))

        _ = try fixture.store.add(
            text: "ls -la /b/", language: .shell, origin: .manual, appName: nil, at: base)
        #expect(try fixture.store.list(limit: 10).first?.origin == .manual)

        _ = try fixture.store.add(
            text: "ls -la /c/", language: .shell, origin: .auto, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base)
        let snippet = try #require(try fixture.store.list(limit: 10).first)
        #expect(snippet.id == id)
        #expect(snippet.origin == .manual)
    }

    @Test func originPriorityOrdersManualHistoryAuto() {
        #expect(SnippetOrigin.manual.priority == 2)
        #expect(SnippetOrigin.history.priority == 1)
        #expect(SnippetOrigin.auto.priority == 0)
    }

    @Test func searchFindsAnyVariant() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))
        _ = try fixture.store.add(
            text: "ls -la /b/", language: .shell, origin: .auto, appName: nil,
            at: base.addingTimeInterval(60))

        #expect(try fixture.store.search("/a/", limit: 5).map(\.id) == [id])
        #expect(try fixture.store.search("/b/", limit: 5).map(\.id) == [id])
        #expect(try fixture.store.search("ls -la", limit: 5).map(\.id) == [id])
    }

    @Test func snippetSearchTextCoversAllVariants() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "LS -la /Über/", language: .shell, origin: .auto, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "LS -la /b/", language: .shell, origin: .auto, appName: nil, at: base)

        let snippet = try #require(try fixture.store.search("über", limit: 5).first)
        #expect(snippet.searchText.contains(SearchText.fold("LS -la /Über/")))
        #expect(snippet.searchText.contains(SearchText.fold("LS -la /b/")))
        #expect(snippet.comment == nil)
    }

    @Test func setCommentRoundTrips() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))

        #expect(try fixture.store.setComment(id: id, comment: "  list the folder \n"))
        #expect(try fixture.store.list(limit: 5).first?.comment == "list the folder")

        #expect(try fixture.store.setComment(id: id, comment: "  "))
        #expect(try fixture.store.list(limit: 5).first?.comment == nil)

        #expect(try fixture.store.setComment(id: id, comment: "again"))
        #expect(try fixture.store.setComment(id: id, comment: nil))
        #expect(try fixture.store.list(limit: 5).first?.comment == nil)
    }

    @Test func setCommentIsSearchable() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))

        #expect(try fixture.store.setComment(id: id, comment: "rotate nightly"))
        #expect(try fixture.store.search("nightly", limit: 5).map(\.id) == [id])
        #expect(try fixture.store.search("/a/", limit: 5).map(\.id) == [id])

        #expect(try fixture.store.setComment(id: id, comment: nil))
        #expect(try fixture.store.search("nightly", limit: 5).isEmpty)
        #expect(try fixture.store.search("/a/", limit: 5).map(\.id) == [id])
    }

    @Test func setCommentOnMissingSnippetReturnsFalse() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))
        _ = try fixture.store.delete(id: id)

        #expect(try fixture.store.setComment(id: id, comment: "late") == false)
        #expect(try fixture.store.count() == 0)
    }

    @Test func longCommentIsCapped() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))

        #expect(try fixture.store.setComment(id: id, comment: String(repeating: "x", count: 5000)))
        #expect(try fixture.store.list(limit: 5).first?.comment?.count == 2000)
    }

    @Test func commentCapCountsCharactersAndLeavesNoTrailingWhitespace() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let id = try insertedID(
            try fixture.store.add(
                text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base))

        for unit in ["é", "👨‍👩‍👧"] {
            #expect(
                try fixture.store.setComment(
                    id: id, comment: String(repeating: unit, count: 2001)))
            let stored = try #require(try fixture.store.list(limit: 5).first?.comment)
            #expect(stored.count == 2000)
            #expect(stored == String(repeating: unit, count: 2000))
        }

        let padded = String(repeating: "x", count: 1999) + "   tail"
        #expect(try fixture.store.setComment(id: id, comment: padded))
        #expect(
            try fixture.store.list(limit: 5).first?.comment == String(repeating: "x", count: 1999))
    }

    @Test func differentLanguagesDoNotMerge() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "replicas: 2", language: .yaml, origin: .auto, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "replicas: 3", language: .shell, origin: .auto, appName: nil, at: base)

        #expect(try fixture.store.count() == 2)
    }

    @Test func migrationMergesVersion12Snippets() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        try Migrator(migrations: Array(Schema.migrations.prefix(12))).migrate(database)
        let rejectedText = "rm -rf /tmp/old"
        let rows:
            [(
                text: String, app: String, count: Int64, created: Double, last: Double,
                origin: String
            )] = [
                ("ls -la /a/", "Terminal", 2, 10, 30, "auto"),
                ("ls -la /b/", "iTerm2", 3, 5, 20, "history"),
                ("kubectl get pods", "Terminal", 1, 7, 8, "auto"),
            ]
        try database.write { connection in
            for row in rows {
                try connection.execute(
                    """
                    INSERT INTO snippets
                        (text, hash, language, origin, app_name, search_text, created_at,
                         last_copied_at, copy_count)
                    VALUES (?, ?, 'shell', ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(row.text), .text(ContentHashing.exactHash(row.text)),
                        .text(row.origin), .text(row.app), .text(SearchText.fold(row.text)),
                        .double(row.created), .double(row.last), .int(row.count),
                    ])
            }
            try connection.execute(
                "INSERT INTO snippet_rejections(hash) VALUES (?)",
                [.text(ContentHashing.exactHash(rejectedText))])
        }

        try Schema.migrator.migrate(database)

        let store = SnippetStore(database: database)
        #expect(try store.count() == 2)
        let merged = try #require(try store.search("/a/", limit: 5).first)
        #expect(merged.copyCount == 5)
        #expect(merged.createdAt == Date(timeIntervalSince1970: 5))
        #expect(merged.lastCopiedAt == Date(timeIntervalSince1970: 30))
        #expect(merged.origin == .history)
        #expect(merged.variantCount == 2)
        #expect(merged.text == "ls -la /a/")
        #expect(merged.appName == "Terminal")
        #expect(merged.searchText.contains("ls -la /a/"))
        #expect(merged.searchText.contains("ls -la /b/"))
        #expect(merged.shapeHash == SnippetShape.hash(of: "ls -la /a/", language: .shell))
        #expect(try store.search("/b/", limit: 5).map(\.id) == [merged.id])
        #expect(try store.variants(of: merged.id).map(\.copyCount) == [2, 3])
        let other = try #require(try store.search("kubectl", limit: 5).first)
        #expect(other.variantCount == 1)
        #expect(other.copyCount == 1)
        #expect(
            try store.add(text: rejectedText, language: .shell, origin: .auto, appName: nil)
                == .rejected)
        // The merged snippet takes new variants after the migration.
        #expect(
            try store.add(text: "ls -la /c/", language: .shell, origin: .auto, appName: nil)
                == .bumped(merged.id))
        let seedTables = try database.read { connection in
            try connection.query(
                """
                SELECT name FROM sqlite_master WHERE name = 'snippet_variant_seed'
                UNION SELECT name FROM sqlite_temp_master WHERE name = 'snippet_variant_seed'
                """
            ) { $0.text(0) }
        }
        #expect(seedTables.isEmpty)
    }

    private func variantOrigins(_ database: Database) throws -> [String: String] {
        try database.read { connection in
            Dictionary(
                uniqueKeysWithValues: try connection.query(
                    "SELECT text, origin FROM snippet_variants"
                ) { ($0.text(0), $0.text(1)) })
        }
    }

    @Test func eachVariantRecordsHowItCameIn() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.add(
            text: "ls -la /a/", language: .shell, origin: .auto, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "ls -la /b/", language: .shell, origin: .history, appName: nil, at: base)
        _ = try fixture.store.add(
            text: "ls -la /c/", language: .shell, origin: .manual, appName: nil, at: base)

        #expect(try fixture.store.count() == 1)
        #expect(
            try variantOrigins(fixture.database)
                == ["ls -la /a/": "auto", "ls -la /b/": "history", "ls -la /c/": "manual"])
    }

    @Test func migrationRecordsEachVariantsOriginThroughTheMerge() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        try Migrator(migrations: Array(Schema.migrations.prefix(12))).migrate(database)
        try database.write { connection in
            for (text, origin) in [("ls -la /a/", "auto"), ("ls -la /b/", "history")] {
                try connection.execute(
                    """
                    INSERT INTO snippets
                        (text, hash, language, origin, app_name, search_text, created_at,
                         last_copied_at, copy_count)
                    VALUES (?, ?, 'shell', ?, NULL, ?, 1, 2, 1)
                    """,
                    [
                        .text(text), .text(ContentHashing.exactHash(text)), .text(origin),
                        .text(SearchText.fold(text)),
                    ])
            }
        }

        try Schema.migrator.migrate(database)

        #expect(try SnippetStore(database: database).count() == 1)
        #expect(
            try variantOrigins(database) == ["ls -la /a/": "auto", "ls -la /b/": "history"])
    }

    /// Process substitution once hung the shape scanner, and with it migration 13 at launch.
    @Test func migrationCompletesOnProcessSubstitution() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open(migrated: false)
        try Migrator(migrations: Array(Schema.migrations.prefix(12))).migrate(database)
        let texts = [
            "diff <(ls a) <(ls b)", "tee >(gzip)", "source <(kubectl completion zsh)",
            "cat <(", "echo $(",
        ]
        try database.write { connection in
            for text in texts {
                try connection.execute(
                    """
                    INSERT INTO snippets
                        (text, hash, language, origin, app_name, search_text, created_at,
                         last_copied_at, copy_count)
                    VALUES (?, ?, 'shell', 'auto', NULL, ?, 1, 2, 1)
                    """,
                    [
                        .text(text), .text(ContentHashing.exactHash(text)),
                        .text(SearchText.fold(text)),
                    ])
            }
        }

        try Schema.migrator.migrate(database)

        let store = SnippetStore(database: database)
        #expect(try store.count() == texts.count)
        #expect(
            try store.add(text: "tee >(xz)", language: .shell, origin: .auto, appName: nil)
                != .rejected)
    }

    @Test func migrationCreatesTables() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }

        let names = try fixture.database.read { connection in
            try connection.query(
                "SELECT name FROM sqlite_master WHERE name IN (?, ?, ?, ?)",
                [
                    .text("snippets"), .text("snippets_fts"), .text("snippet_rejections"),
                    .text("snippet_variants"),
                ]
            ) { $0.text(0) }
        }

        #expect(
            Set(names) == ["snippets", "snippets_fts", "snippet_rejections", "snippet_variants"])
    }
}

private enum SnippetTestError: Error {
    case unexpectedOutcome(String)
}

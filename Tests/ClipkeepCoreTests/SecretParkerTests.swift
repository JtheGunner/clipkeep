import Foundation
import Testing

@testable import ClipkeepCore

private final class MemoryVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    var failStore = false

    func store(_ secret: String, key: String) throws {
        if failStore { throw SecretVaultError.keychain(-1) }
        lock.withLock { items[key] = secret }
    }
    func read(key: String) throws -> String? { lock.withLock { items[key] } }
    func delete(key: String) throws { lock.withLock { _ = items.removeValue(forKey: key) } }
    func keys() throws -> [String] { lock.withLock { Array(items.keys) } }
    var values: [String] { lock.withLock { Array(items.values) } }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var errors: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Suite struct SecretParkerTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var secret: String { "sk-ant-api03-" + String(repeating: "aB3dE6gH9k", count: 8) }
    private let browser = CopyContext(
        appBundleID: "com.apple.Safari", appName: "Safari", url: "https://console.example.com/keys")

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let vault = MemoryVault()
        let errors = ErrorBox()
        let store: ContentStore
        let parker: SecretParker
        let pipeline: CapturePipeline

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
            let errors = errors
            parker = SecretParker(
                database: database, store: store, vault: vault, onError: { _ in errors.add() })
            pipeline = CapturePipeline(store: store, secretSink: parker)
        }

        func count(_ table: String) throws -> Int64 {
            try database.read {
                try $0.query("SELECT count(*) FROM \(table)") { $0.int(0) }.first ?? 0
            }
        }
    }

    /// Every text and blob value of every table, including the full-text index tables.
    private func allStoredText(_ database: Database) throws -> [String] {
        try database.read { connection in
            let tables = try connection.query(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ) { $0.text(0) }
            var values: [String] = []
            for table in tables where !table.hasPrefix("sqlite_") {
                let columns = try connection.query("PRAGMA table_info(\"\(table)\")") { $0.text(1) }
                for column in columns {
                    values += try connection.query(
                        "SELECT CAST(\"\(column)\" AS TEXT) FROM \"\(table)\" WHERE \"\(column)\" IS NOT NULL"
                    ) { $0.text(0) }
                }
            }
            return values
        }
    }

    @Test func aSecretIsParkedAndOnlyAPlaceholderIsStored() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let outcome = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: "key: \(secret)"), source: browser, at: base)
        #expect(outcome == .skipped(.secret))
        #expect(fixture.errors.errors == 0)
        #expect(fixture.vault.values == ["key: \(secret)"])

        let pending = try fixture.parker.pending()
        #expect(pending.count == 1)
        let parked = try #require(pending.first)
        #expect(parked.kind == .anthropicKey)
        #expect(parked.state == .parked)
        #expect(parked.label.hasPrefix("Anthropic API-Key · console.example.com · "))
        #expect(parked.label.hasSuffix(" → gesichert"))

        let kind = try fixture.database.read {
            try $0.query("SELECT text, kind FROM contents") { [$0.text(0), $0.text(1)] }
        }
        #expect(kind == [[parked.label, "secret"]])
    }

    @Test func theSecretIsInNoTableAndNotInTheSearchIndex() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: "key: \(secret)"), source: browser, at: base)
        let stored = try allStoredText(fixture.database)
        #expect(!stored.isEmpty)
        let middle = String(secret.dropFirst(20).prefix(16))
        #expect(stored.allSatisfy { !$0.contains(secret) && !$0.contains(middle) })
        // The search index finds the placeholder but never the secret.
        let found = try SearchService(database: fixture.database).search(
            "console.example.com")
        #expect(found.count == 1)
        #expect(
            try SearchService(database: fixture.database).search(middle).isEmpty)
    }

    @Test func parkedSecretsSurviveARestart() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        let reopened = try fixture.temp.open()
        let parker = SecretParker(
            database: reopened, store: ContentStore(database: reopened), vault: fixture.vault)
        let pending = try parker.pending()
        #expect(pending.count == 1)
        #expect(try parker.reveal(id: pending[0].id) == secret)
    }

    @Test func copyingTheSameSecretAgainAddsACopyNotAnEntry() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        for index in 0..<3 {
            _ = try fixture.pipeline.process(
                PasteboardSnapshot(changeCount: index, text: secret), source: browser,
                at: base.addingTimeInterval(Double(index)))
        }
        #expect(try fixture.count("parked_secrets") == 1)
        #expect(fixture.vault.values.count == 1)
        #expect(try fixture.count("contents") == 1)
        #expect(try fixture.count("copy_events") == 3)
    }

    @Test func aTransferIsConfirmedBeforeAnythingLeavesTheKeychain() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        let id = try #require(try fixture.parker.pending().first).id

        #expect(throws: ParkingError.notTransferred) { try fixture.parker.deleteFromVault(id: id) }
        #expect(try fixture.parker.purgeTransferred() == 0)
        #expect(fixture.vault.values.count == 1)

        try fixture.parker.markTransferred(id: id, at: base.addingTimeInterval(60))
        #expect(throws: ParkingError.notParked) { try fixture.parker.markTransferred(id: id) }
        #expect(fixture.vault.values.count == 1)
        #expect(try fixture.parker.pending().isEmpty)

        #expect(try fixture.parker.purgeTransferred(at: base.addingTimeInterval(120)) == 1)
        #expect(fixture.vault.values.isEmpty)
        let done = try #require(try fixture.parker.secret(id: id))
        #expect(done.state == .deleted)
        #expect(done.transferredAt == base.addingTimeInterval(60))
        #expect(done.deletedAt == base.addingTimeInterval(120))
        #expect(throws: ParkingError.vaultItemMissing) { _ = try fixture.parker.reveal(id: id) }
        #expect(throws: ParkingError.notFound) { try fixture.parker.markTransferred(id: 999) }
    }

    @Test func aFailingVaultStoresNothingAndReportsTheError() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        fixture.vault.failStore = true
        let outcome = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        #expect(outcome == .skipped(.secret))
        #expect(fixture.errors.errors == 1)
        #expect(try fixture.count("contents") == 0)
        #expect(try fixture.count("parked_secrets") == 0)
        #expect(try allStoredText(fixture.database).allSatisfy { !$0.contains(secret) })
    }

    @Test func aFailingDatabaseLeavesNoKeychainItemOrPlaceholder() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fixture.database.write { try $0.execute("DROP TABLE parked_secrets") }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        #expect(fixture.errors.errors == 1)
        #expect(fixture.vault.values.isEmpty)
        #expect(try fixture.count("contents") == 0)
    }

    @Test func reconcileRemovesOrphansAndMarksMissingItemsAsLost() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        try fixture.vault.store("left behind", key: "orphan")
        #expect(try fixture.parker.reconcile() == (orphansRemoved: 1, lost: 0))
        #expect(fixture.vault.values == [secret])

        let id = try #require(try fixture.parker.pending().first).id
        for key in try fixture.vault.keys() { try fixture.vault.delete(key: key) }
        #expect(try fixture.parker.reconcile() == (orphansRemoved: 0, lost: 1))
        #expect(try fixture.parker.secret(id: id)?.state == .lost)
        #expect(try fixture.parker.pending().isEmpty)
    }

    @Test func placeholderNamesFallBackToTheAppAndHideNothingElse() {
        let label = SecretParker.label(
            kind: .githubToken, context: CopyContext(appName: "Terminal"), copiedAt: base)
        #expect(label.hasPrefix("GitHub-Token · Terminal · "))
        let bare = SecretParker.label(kind: .jwt, context: CopyContext(), copiedAt: base)
        #expect(bare.hasPrefix("JWT · "))
    }
}

@Suite struct KeychainSecretVaultTests {
    @Test func storesReadsListsAndDeletes() throws {
        let vault = KeychainSecretVault(service: "li.wuermli.clipkeep.tests.\(UUID().uuidString)")
        let key = UUID().uuidString
        defer { try? vault.delete(key: key) }
        #expect(try vault.read(key: key) == nil)
        try vault.store("parked value", key: key)
        #expect(try vault.read(key: key) == "parked value")
        #expect(try vault.keys() == [key])
        #expect(throws: SecretVaultError.self) { try vault.store("again", key: key) }
        try vault.delete(key: key)
        try vault.delete(key: key)
        #expect(try vault.read(key: key) == nil)
        #expect(try vault.keys().isEmpty)
    }
}

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
    /// Parked secrets, without the vault entry that holds the fingerprint key.
    var values: [String] {
        lock.withLock { items.filter { $0.key != SecretParker.fingerprintKeyName }.map(\.value) }
    }
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

    @Test func parkingReportsWhetherTheSecretIsSafe() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        #expect(fixture.parker.park(secret: secret, context: browser, copiedAt: base))
        // Parking it again only adds a copy to the placeholder.
        #expect(fixture.parker.park(secret: secret, context: browser, copiedAt: base))
        fixture.vault.failStore = true
        #expect(!fixture.parker.park(secret: secret + "x", context: browser, copiedAt: base))
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

    @Test func reconcileAdoptsUnknownKeychainItemsInsteadOfDeletingThem() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        try fixture.vault.store("left behind by a crash", key: "orphan")
        #expect(try fixture.parker.reconcile() == (adopted: 1, lost: 0))
        #expect(fixture.vault.values.count == 2)
        let pending = try fixture.parker.pending()
        #expect(pending.count == 2)
        let adopted = try #require(pending.first { $0.label.hasPrefix("Wiederhergestelltes") })
        #expect(try fixture.parker.reveal(id: adopted.id) == "left behind by a crash")
        #expect(try fixture.parker.reconcile() == (adopted: 0, lost: 0))
    }

    @Test func aFreshDatabaseNeverDestroysExistingKeychainSecrets() throws {
        let first = try Fixture()
        defer { first.temp.remove() }
        _ = try first.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        let second = try TemporaryDatabase()
        defer { second.remove() }
        let freshDatabase = try second.open()
        let parker = SecretParker(
            database: freshDatabase, store: ContentStore(database: freshDatabase),
            vault: first.vault)
        _ = try parker.reconcile()
        #expect(first.vault.values == [secret])
        let revealed = try parker.reveal(id: try #require(try parker.pending().first).id)
        #expect(revealed == secret)
    }

    @Test func reconcileMarksMissingItemsAsLostOrDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 2, text: "other " + secret), source: browser,
            at: base.addingTimeInterval(1))
        let ids = try fixture.parker.pending().map(\.id)
        try fixture.parker.markTransferred(id: ids[1])
        for key in try fixture.vault.keys() { try fixture.vault.delete(key: key) }

        #expect(try fixture.parker.reconcile() == (adopted: 0, lost: 1))
        #expect(try fixture.parker.secret(id: ids[0])?.state == .lost)
        #expect(try fixture.parker.secret(id: ids[1])?.state == .deleted)
        #expect(try fixture.parker.pending().isEmpty)
    }

    @Test func retentionKeepsPlaceholdersOfLiveSecrets() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        let far = base.addingTimeInterval(4_000 * 86_400)
        _ = try RankingService(database: fixture.database).applyRetention(now: far)
        #expect(try fixture.count("contents") == 1)
        let parked = try #require(try fixture.parker.pending().first)
        #expect(parked.contentID != nil)
    }

    @Test func aRepeatedCopyRelinksThePlaceholderAndMarksItAsSecret() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        let id = try #require(try fixture.parker.pending().first).id
        try fixture.database.write { connection in
            try connection.execute("DELETE FROM contents")
        }
        #expect(try fixture.parker.secret(id: id)?.contentID == nil)
        _ = try fixture.pipeline.process(
            PasteboardSnapshot(changeCount: 2, text: secret), source: browser,
            at: base.addingTimeInterval(5))
        let relinked = try #require(try fixture.parker.secret(id: id))
        #expect(relinked.contentID != nil)
        let kinds = try fixture.database.read {
            try $0.query("SELECT kind FROM contents") { $0.text(0) }
        }
        #expect(kinds == ["secret"])
        #expect(try fixture.count("parked_secrets") == 1)
    }

    @Test func contextDetailsAreNeverReadForSecrets() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        struct Leaky: ContextDetailProviding {
            let leak: String
            func details(for source: CopyContext) -> CopyContext {
                var result = source
                result.windowTitle = "export TOKEN=\(leak)"
                result.url = "https://example.com/\(leak)"
                return result
            }
        }
        let pipeline = CapturePipeline(
            store: fixture.store, secretSink: fixture.parker, contextDetails: Leaky(leak: secret))
        _ = try pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: secret), source: browser, at: base)
        let stored = try allStoredText(fixture.database)
        #expect(stored.allSatisfy { !$0.contains(String(secret.dropFirst(20).prefix(16))) })
    }

    @Test func aPauseDuringSecretHandlingKeepsTheSecretOutEntirely() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let control = CaptureControl(paused: true)
        let pipeline = CapturePipeline(
            store: fixture.store, secretSink: fixture.parker, control: control)
        #expect(
            try pipeline.process(PasteboardSnapshot(changeCount: 1, text: secret), source: browser)
                == .skipped(.paused))
        #expect(fixture.vault.values.isEmpty)
        #expect(try fixture.count("parked_secrets") == 0)
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

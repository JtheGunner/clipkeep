import Foundation
import Testing

@testable import ClipkeepCore

private final class MemoryVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    var failDelete = false
    func store(_ secret: String, key: String) throws { lock.withLock { items[key] = secret } }
    func read(key: String) throws -> String? { lock.withLock { items[key] } }
    func delete(key: String) throws {
        if failDelete { throw SecretVaultError.keychain(-1) }
        lock.withLock { _ = items.removeValue(forKey: key) }
    }
    func keys() throws -> [String] { lock.withLock { Array(items.keys) } }
    var parkedCount: Int {
        lock.withLock { items.keys.filter { $0 != SecretParker.fingerprintKeyName }.count }
    }
}

private final class ParkedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int64] = []
    func add(_ id: Int64) { lock.withLock { ids.append(id) } }
    var all: [Int64] { lock.withLock { ids } }
}

@Suite struct NotSecretTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let browser = CopyContext(
        appBundleID: "com.apple.Safari", appName: "Safari", url: "https://console.example.com/keys")
    private var secret: String { "sk-ant-api03-" + String(repeating: "aB3dE6gH9k", count: 8) }

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let vault = MemoryVault()
        let parked = ParkedLog()
        let store: ContentStore
        let parker: SecretParker
        let pipeline: CapturePipeline

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
            let parked = parked
            parker = SecretParker(
                database: database, store: store, vault: vault, onParked: { parked.add($0.id) })
            pipeline = CapturePipeline(store: store, secretSink: parker)
        }

        func contents() throws -> [(text: String, kind: String)] {
            try database.read {
                try $0.query("SELECT text, kind FROM contents ORDER BY id") {
                    ($0.text(0), $0.text(1))
                }
            }
        }

        func events(text: String) throws -> Int64 {
            try database.read {
                try $0.query(
                    """
                    SELECT count(*) FROM copy_events e JOIN contents c ON c.id = e.content_id
                    WHERE c.text = ?
                    """, [.text(text)]
                ) { $0.int(0) }.first ?? 0
            }
        }

        func copy(_ text: String, at date: Date, context: CopyContext) throws -> CaptureOutcome {
            try pipeline.process(
                PasteboardSnapshot(changeCount: 1, text: text), source: context, at: date)
        }
    }

    @Test func undoingRestoresTheEntryWithAllItsCopies() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        _ = try fixture.copy(secret, at: base.addingTimeInterval(60), context: browser)
        let parked = try #require(try fixture.parker.pending().first)

        try fixture.parker.markNotSecret(id: parked.id)

        let contents = try fixture.contents()
        #expect(contents.count == 1)
        #expect(contents.first?.text == secret)
        #expect(contents.first?.kind != ContentKind.secret.rawValue)
        #expect(try fixture.events(text: secret) == 2)
        // Back to a normal entry: out of the Keychain and out of the transfer queue.
        #expect(fixture.vault.parkedCount == 0)
        #expect(try fixture.parker.pending().isEmpty)
        // With its original context.
        let context = try fixture.database.read {
            try $0.query("SELECT app_name, url FROM copy_events ORDER BY copied_at LIMIT 1") {
                ($0.text(0), $0.text(1))
            }
        }
        #expect(context.first?.0 == "Safari")
        #expect(context.first?.1 == "https://console.example.com/keys")
    }

    @Test func theTextIsNotParkedAgainAfterwards() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        let parked = try #require(try fixture.parker.pending().first)
        try fixture.parker.markNotSecret(id: parked.id)

        let outcome = try fixture.copy(secret, at: base.addingTimeInterval(120), context: browser)
        guard case .recorded = outcome else {
            Issue.record("expected the copy to be recorded")
            return
        }
        #expect(fixture.vault.parkedCount == 0)
        #expect(try fixture.events(text: secret) == 2)
        #expect(fixture.parked.all.count == 1)
    }

    @Test func otherSecretsAreStillParked() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        try fixture.parker.markNotSecret(id: try #require(try fixture.parker.pending().first).id)
        let other = "sk-ant-api03-" + String(repeating: "Zz9yY8xX7w", count: 8)
        let outcome = try fixture.copy(other, at: base.addingTimeInterval(5), context: browser)
        #expect(outcome == .skipped(.secret))
        #expect(try fixture.parker.pending().count == 1)
    }

    @Test func exceptionsAreListedWithoutTheTextAndCanBeRemoved() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        try fixture.parker.markNotSecret(id: try #require(try fixture.parker.pending().first).id)

        let exceptions = try fixture.parker.exceptions()
        #expect(exceptions.count == 1)
        #expect(!(exceptions.first?.label.contains("aB3dE6gH9k") ?? true))
        #expect(fixture.parker.isException(secret))

        try fixture.parker.removeException(id: try #require(exceptions.first).id)
        #expect(try fixture.parker.exceptions().isEmpty)
        #expect(!fixture.parker.isException(secret))
        // The text counts as a secret again.
        let outcome = try fixture.copy(secret, at: base.addingTimeInterval(300), context: browser)
        #expect(outcome == .skipped(.secret))
        #expect(try fixture.parker.pending().count == 1)
    }

    @Test func theDatabaseNeverHoldsTheTextInTheExceptionList() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        try fixture.parker.markNotSecret(id: try #require(try fixture.parker.pending().first).id)
        let stored = try fixture.database.read {
            try $0.query("SELECT fingerprint, label FROM secret_exceptions") {
                $0.text(0) + $0.text(1)
            }
        }
        #expect(stored.allSatisfy { !$0.contains(secret) })
    }

    @Test func undoingNeedsTheValueOnceItMovedToBitwarden() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        let parked = try #require(try fixture.parker.pending().first)
        try fixture.parker.markTransferred(id: parked.id)
        try fixture.parker.deleteFromVault(id: parked.id)

        #expect(throws: ParkingError.vaultItemMissing) {
            try fixture.parker.markNotSecret(id: parked.id)
        }
        try fixture.parker.markNotSecret(id: parked.id, value: secret)
        #expect(try fixture.events(text: secret) == 1)
        #expect(fixture.parker.isException(secret))
    }

    @Test func undoingAnUnknownSecretFails() async throws {
        let fixture = try Fixture()
        #expect(throws: ParkingError.notFound) { try fixture.parker.markNotSecret(id: 42) }
    }

    @Test func aCopyFetchedBackFromBitwardenCreatesNoNewEntry() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        let parked = try #require(try fixture.parker.pending().first)
        try fixture.parker.markTransferred(id: parked.id)
        try fixture.parker.deleteFromVault(id: parked.id)
        let entries = try fixture.contents().count

        let outcome = try fixture.copy(secret, at: base.addingTimeInterval(900), context: browser)
        #expect(outcome == .skipped(.secret))
        #expect(try fixture.parker.pending().isEmpty)
        #expect(fixture.vault.parkedCount == 0)
        #expect(try fixture.contents().count == entries)
        #expect(fixture.parked.all.count == 1)
    }

    @Test func theCallbackFiresOncePerNewSecret() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        _ = try fixture.copy(secret, at: base.addingTimeInterval(10), context: browser)
        #expect(fixture.parked.all.count == 1)
    }

    @Test func undoingKeepsSessionsAndTimesConsistent() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy("let x = 1", at: base, context: browser)
        _ = try fixture.copy(secret, at: base.addingTimeInterval(30), context: browser)
        _ = try fixture.copy(secret, at: base.addingTimeInterval(90), context: browser)
        _ = try fixture.copy("let y = 2", at: base.addingTimeInterval(120), context: browser)
        try fixture.parker.markNotSecret(id: try #require(try fixture.parker.pending().first).id)

        let times = try fixture.database.read {
            try $0.query(
                "SELECT first_seen_at, last_copied_at FROM contents WHERE text = ?", [.text(secret)]
            ) {
                ($0.double(0), $0.double(1))
            }
        }
        #expect(times.first?.0 == base.addingTimeInterval(30).timeIntervalSince1970)
        #expect(times.first?.1 == base.addingTimeInterval(90).timeIntervalSince1970)
        let dangling = try fixture.database.read {
            try $0.query("SELECT count(*) FROM copy_events WHERE session_id IS NULL") { $0.int(0) }
                .first ?? 0
        }
        #expect(dangling == 0)
        #expect(try fixture.events(text: secret) == 2)
    }

    @Test func aPlaceholderSharedWithAnotherSecretIsLeftAlone() async throws {
        let fixture = try Fixture()
        // Two different keys copied in the same second from the same page share one label.
        let other = "sk-ant-api03-" + String(repeating: "Zz9yY8xX7w", count: 8)
        _ = try fixture.copy(secret, at: base, context: browser)
        _ = try fixture.copy(other, at: base, context: browser)
        let all = try fixture.parker.pending()
        #expect(all.count == 2)
        #expect(all[0].contentID == all[1].contentID)

        try fixture.parker.markNotSecret(id: all[0].id)
        #expect(try fixture.parker.pending().count == 1)
        let placeholders = try fixture.database.read {
            try $0.query("SELECT count(*) FROM contents WHERE kind = 'secret'") { $0.int(0) }.first
                ?? 0
        }
        #expect(placeholders == 1)
        #expect(try fixture.events(text: secret) == 1)
    }

    @Test func aCopyWaitingForTheLockIsNotParkedAfterTheException() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        try fixture.parker.markNotSecret(id: try #require(try fixture.parker.pending().first).id)
        // What the pipeline would do after it checked the exception too early.
        fixture.parker.handle(
            secret: secret, context: browser, copiedAt: base.addingTimeInterval(1))
        #expect(try fixture.parker.pending().isEmpty)
        #expect(fixture.vault.parkedCount == 0)
    }

    @Test func aFailedKeychainDeleteIsFinishedLater() async throws {
        let fixture = try Fixture()
        _ = try fixture.copy(secret, at: base, context: browser)
        let id = try #require(try fixture.parker.pending().first).id
        fixture.vault.failDelete = true
        try fixture.parker.markNotSecret(id: id)
        #expect(fixture.vault.parkedCount == 1)
        #expect(try fixture.parker.pending().isEmpty)

        fixture.vault.failDelete = false
        _ = try fixture.parker.reconcile()
        #expect(fixture.vault.parkedCount == 0)
    }
}

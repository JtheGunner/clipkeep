import Foundation
import Testing

@testable import ClipkeepCore

private final class MemoryVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func store(_ secret: String, key: String) throws { lock.withLock { items[key] = secret } }
    func read(key: String) throws -> String? { lock.withLock { items[key] } }
    func delete(key: String) throws { lock.withLock { _ = items.removeValue(forKey: key) } }
    func keys() throws -> [String] { lock.withLock { Array(items.keys) } }
    var parkedValues: [String] {
        lock.withLock { items.filter { $0.key != SecretParker.fingerprintKeyName }.map(\.value) }
    }
}

/// A Bitwarden vault in memory with switchable failures.
private final class FakeBitwarden: BitwardenClient, @unchecked Sendable {
    static let goodPassword = "correct horse"
    static let sessionKey = "session-key-1"

    private let lock = NSLock()
    private var stored: [BitwardenNote] = []
    private var created = 0
    private var failure: BitwardenError?
    private var failAfterCreates: Int?
    private var corruptNotes = false
    private(set) var statusValue: BitwardenStatus = .locked

    var notes: [BitwardenNote] { lock.withLock { stored } }
    func fail(with error: BitwardenError?) { lock.withLock { failure = error } }
    func failCreates(after count: Int?, with error: BitwardenError) {
        lock.withLock {
            failAfterCreates = count
            failure = nil
            failureForCreate = error
        }
    }
    private var failureForCreate: BitwardenError = .offline
    private var rejectedSecret: String?
    func rejectCreate(ofSecret secret: String) { lock.withLock { rejectedSecret = secret } }
    func echoWrongNotes() { lock.withLock { corruptNotes = true } }
    func preload(_ note: BitwardenNote) { lock.withLock { stored.append(note) } }

    private func check(session: String?) throws {
        try lock.withLock {
            if let failure { throw failure }
            if session != Self.sessionKey { throw BitwardenError.locked }
        }
    }

    func status(session: String?) async throws -> BitwardenStatus {
        if let failure = lock.withLock({ failure }) { throw failure }
        return session == Self.sessionKey ? .unlocked : .locked
    }

    func unlock(masterPassword: String) async throws -> String {
        if let failure = lock.withLock({ failure }) { throw failure }
        guard masterPassword == Self.goodPassword else {
            throw BitwardenError.invalidMasterPassword
        }
        return Self.sessionKey
    }

    func lock(session: String) async throws {}
    func sync(session: String) async throws { try check(session: session) }
    func folderID(named name: String, session: String) async throws -> String {
        try check(session: session)
        return "folder-1"
    }

    func createSecureNote(
        name: String, secret: String, clipkeepID: String, folderID: String, session: String
    ) async throws -> BitwardenNote {
        try check(session: session)
        return try lock.withLock {
            if let limit = failAfterCreates, created >= limit { throw failureForCreate }
            if secret == rejectedSecret { throw BitwardenError.commandFailed }
            created += 1
            let note = BitwardenNote(
                id: "item-\(created)", notes: secret, clipkeepID: clipkeepID)
            stored.append(note)
            return corruptNotes
                ? BitwardenNote(id: note.id, notes: "other", clipkeepID: clipkeepID) : note
        }
    }

    func notes(inFolder folderID: String, session: String) async throws -> [BitwardenNote] {
        try check(session: session)
        return lock.withLock { stored }
    }
}

@Suite struct BitwardenSyncTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let context = CopyContext(
        appBundleID: "com.apple.Safari", appName: "Safari", url: "https://console.example.com/keys")

    private func secret(_ index: Int) -> String {
        "sk-ant-api03-" + String(repeating: "aB3dE6gH9k", count: 8) + String(index)
    }

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let vault = MemoryVault()
        let bitwarden = FakeBitwarden()
        let parker: SecretParker
        let sync: BitwardenSync

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            parker = SecretParker(
                database: database, store: ContentStore(database: database), vault: vault)
            sync = BitwardenSync(client: bitwarden, parker: parker)
        }
    }

    private func park(_ fixture: Fixture, count: Int) {
        for index in 0..<count {
            fixture.parker.handle(
                secret: secret(index), context: context,
                copiedAt: base.addingTimeInterval(Double(index) * 10))
        }
    }

    @Test func unlockingMovesEverythingAndEmptiesTheKeychain() async throws {
        let fixture = try Fixture()
        park(fixture, count: 3)
        let report = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(report == TransferReport(transferred: 3, remaining: 0, failure: nil))
        #expect(fixture.vault.parkedValues.isEmpty)
        #expect(Set(fixture.bitwarden.notes.compactMap(\.notes)) == Set((0..<3).map(secret)))
        #expect(try fixture.parker.pending().isEmpty)
    }

    @Test func wrongMasterPasswordChangesNothing() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        await #expect(throws: BitwardenError.invalidMasterPassword) {
            try await fixture.sync.unlock(masterPassword: "wrong")
        }
        #expect(await !fixture.sync.isUnlocked)
        #expect(fixture.vault.parkedValues.count == 1)
        #expect(try fixture.parker.pending().count == 1)
    }

    @Test func missingBitwardenCLIKeepsEverythingParked() async throws {
        let fixture = try Fixture()
        park(fixture, count: 2)
        fixture.bitwarden.fail(with: .notInstalled)
        await #expect(throws: BitwardenError.notInstalled) {
            try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        }
        #expect(fixture.vault.parkedValues.count == 2)
    }

    @Test func offlineStopsTheRunAndKeepsTheRestParked() async throws {
        let fixture = try Fixture()
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        park(fixture, count: 3)
        fixture.bitwarden.failCreates(after: 0, with: .offline)
        let report = try await fixture.sync.transferPending()
        #expect(report.failure == .offline)
        #expect(report.transferred == 0)
        #expect(report.remaining == 3)
        #expect(fixture.vault.parkedValues.count == 3)
        #expect(await fixture.sync.isUnlocked)
    }

    @Test func aFailureMidwayKeepsTheTransferredOnesAndTheRestParked() async throws {
        let fixture = try Fixture()
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        park(fixture, count: 3)
        fixture.bitwarden.failCreates(after: 1, with: .offline)
        let report = try await fixture.sync.transferPending()
        #expect(report == TransferReport(transferred: 1, remaining: 2, failure: .offline))
        #expect(fixture.vault.parkedValues.count == 2)
        // The retry finishes the job once the network is back.
        fixture.bitwarden.failCreates(after: nil, with: .offline)
        let retry = try await fixture.sync.transferPending()
        #expect(retry == TransferReport(transferred: 2, remaining: 0, failure: nil))
        #expect(fixture.bitwarden.notes.count == 3)
    }

    @Test func aLockedVaultDropsTheSessionAndKeepsTheSecrets() async throws {
        let fixture = try Fixture()
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        park(fixture, count: 1)
        fixture.bitwarden.fail(with: .locked)
        let report = try await fixture.sync.transferPending()
        #expect(report.failure == .locked)
        #expect(await !fixture.sync.isUnlocked)
        #expect(fixture.vault.parkedValues.count == 1)
    }

    @Test func transferringWhileLockedDoesNothing() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        let report = try await fixture.sync.transferPending()
        #expect(report == TransferReport(transferred: 0, remaining: 1, failure: .locked))
        #expect(fixture.vault.parkedValues.count == 1)
    }

    @Test func aNoteAlreadyInTheVaultIsNotCreatedTwice() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        let pending = try #require(try fixture.parker.pending().first)
        // A run that died right after creating the note.
        fixture.bitwarden.preload(
            BitwardenNote(id: "old", notes: secret(0), clipkeepID: pending.vaultKey))
        let report = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(report.transferred == 1)
        #expect(fixture.bitwarden.notes.count == 1)
        #expect(fixture.vault.parkedValues.isEmpty)
    }

    @Test func aNoteTheServerDidNotEchoCorrectlyIsNotTrusted() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        fixture.bitwarden.echoWrongNotes()
        let report = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(report.failure == .unexpectedOutput)
        #expect(report.transferred == 0)
        #expect(fixture.vault.parkedValues.count == 1)
        #expect(try fixture.parker.pending().count == 1)
    }

    @Test func aVanishedKeychainItemDoesNotBlockTheOthers() async throws {
        let fixture = try Fixture()
        park(fixture, count: 2)
        let first = try #require(try fixture.parker.pending().first)
        try fixture.vault.delete(key: first.vaultKey)
        let report = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(report.transferred == 1)
        #expect(report.failure == nil)
    }

    @Test func leftoversOfAnInterruptedRunAreRemovedFromTheKeychain() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        let pending = try #require(try fixture.parker.pending().first)
        try fixture.parker.markTransferred(id: pending.id)
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(fixture.vault.parkedValues.isEmpty)
        #expect(try fixture.parker.secret(id: pending.id)?.state == .deleted)
    }

    @Test func lockingForgetsTheSession() async throws {
        let fixture = try Fixture()
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(await fixture.sync.isUnlocked)
        await fixture.sync.lock()
        #expect(await !fixture.sync.isUnlocked)
        guard case .success(.locked) = await fixture.sync.status() else {
            Issue.record("expected a locked status")
            return
        }
    }

    @Test func statusReportsProblemsInsteadOfThrowing() async throws {
        let fixture = try Fixture()
        fixture.bitwarden.fail(with: .notInstalled)
        let result = await fixture.sync.status()
        #expect(result == .failure(.notInstalled))
    }

    @Test func oneRejectedSecretDoesNotBlockTheOthers() async throws {
        let fixture = try Fixture()
        park(fixture, count: 3)
        fixture.bitwarden.rejectCreate(ofSecret: secret(0))
        let report = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(report == TransferReport(transferred: 2, remaining: 1, failure: .commandFailed))
        #expect(fixture.vault.parkedValues == [secret(0)])
        #expect(
            try await fixture.sync.retrieve(secretID: try fixture.parker.pending()[0].id)
                == secret(0))
    }

    @Test func aNoteWithOurMarkerButOtherContentIsNeverDuplicated() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        let pending = try #require(try fixture.parker.pending().first)
        fixture.bitwarden.preload(
            BitwardenNote(id: "old", notes: "changed", clipkeepID: pending.vaultKey))
        for _ in 0..<2 {
            _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        }
        #expect(fixture.bitwarden.notes.count == 1)
        #expect(fixture.vault.parkedValues.count == 1)
    }

    @Test func aSlowStatusCheckDoesNotWipeANewSession() async throws {
        let fixture = try Fixture()
        let slow = BitwardenSync(client: SlowStatus(), parker: fixture.parker)
        async let status = slow.status()
        try await Task.sleep(for: .milliseconds(30))
        _ = try await slow.unlock(masterPassword: FakeBitwarden.goodPassword)
        _ = await status
        #expect(await slow.isUnlocked)
    }

    @Test func theVaultLocksAfterBeingIdle() async throws {
        let fixture = try Fixture()
        let quick = BitwardenSync(
            client: fixture.bitwarden, parker: fixture.parker, idleTimeout: .milliseconds(100))
        _ = try await quick.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(await quick.isUnlocked)
        // Poll instead of sleeping a fixed time: a busy CI runner delays the timer.
        for _ in 0..<100 where await quick.isUnlocked {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await !quick.isUnlocked)
    }

    // MARK: - Retrieval

    @Test func aParkedSecretComesBackFromTheKeychain() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        let pending = try #require(try fixture.parker.pending().first)
        #expect(try await fixture.sync.retrieve(secretID: pending.id) == secret(0))
    }

    @Test func aTransferredSecretComesBackFromBitwarden() async throws {
        let fixture = try Fixture()
        park(fixture, count: 2)
        let all = try fixture.parker.pending()
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        #expect(fixture.vault.parkedValues.isEmpty)
        #expect(try await fixture.sync.retrieve(secretID: all[1].id) == secret(1))
    }

    @Test func retrievalNeedsAnUnlockedVault() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        let all = try fixture.parker.pending()
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        await fixture.sync.lock()
        await #expect(throws: BitwardenError.locked) {
            try await fixture.sync.retrieve(secretID: all[0].id)
        }
    }

    @Test func retrievingAnUnknownSecretFails() async throws {
        let fixture = try Fixture()
        await #expect(throws: ParkingError.notFound) {
            try await fixture.sync.retrieve(secretID: 999)
        }
    }

    @Test func retrievingWhatBitwardenLostFails() async throws {
        let fixture = try Fixture()
        park(fixture, count: 1)
        let all = try fixture.parker.pending()
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwarden.goodPassword)
        // The note was deleted in Bitwarden meanwhile.
        let emptied = BitwardenSync(client: EmptyVault(), parker: fixture.parker)
        _ = try await emptied.unlock(masterPassword: FakeBitwarden.goodPassword)
        await #expect(throws: ParkingError.vaultItemMissing) {
            try await emptied.retrieve(secretID: all[0].id)
        }
    }
}

private struct EmptyVault: BitwardenClient {
    func status(session: String?) async throws -> BitwardenStatus { .unlocked }
    func unlock(masterPassword: String) async throws -> String { FakeBitwarden.sessionKey }
    func lock(session: String) async throws {}
    func sync(session: String) async throws {}
    func folderID(named name: String, session: String) async throws -> String { "f" }
    func createSecureNote(
        name: String, secret: String, clipkeepID: String, folderID: String, session: String
    ) async throws -> BitwardenNote {
        BitwardenNote(id: "x", notes: secret, clipkeepID: clipkeepID)
    }
    func notes(inFolder folderID: String, session: String) async throws -> [BitwardenNote] { [] }
}

private struct SlowStatus: BitwardenClient {
    func status(session: String?) async throws -> BitwardenStatus {
        try await Task.sleep(for: .milliseconds(200))
        return .locked
    }
    func unlock(masterPassword: String) async throws -> String { FakeBitwarden.sessionKey }
    func lock(session: String) async throws {}
    func sync(session: String) async throws {}
    func folderID(named name: String, session: String) async throws -> String { "f" }
    func createSecureNote(
        name: String, secret: String, clipkeepID: String, folderID: String, session: String
    ) async throws -> BitwardenNote {
        BitwardenNote(id: "x", notes: secret, clipkeepID: clipkeepID)
    }
    func notes(inFolder folderID: String, session: String) async throws -> [BitwardenNote] { [] }
}

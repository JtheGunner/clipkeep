import Foundation

public struct TransferReport: Sendable, Equatable {
    /// Secrets now in Bitwarden and removed from the Keychain.
    public let transferred: Int
    /// Secrets still parked in the Keychain.
    public let remaining: Int
    /// Why the run stopped or why a secret was skipped; nil when everything went through.
    public let failure: BitwardenError?

    public init(transferred: Int, remaining: Int, failure: BitwardenError?) {
        self.transferred = transferred
        self.remaining = remaining
        self.failure = failure
    }
}

/// Moves parked secrets into Bitwarden as secure notes and fetches them back later.
/// The session key lives in this object's memory only: it is never written anywhere, and the
/// master password is handed to `bw` once and not kept.
public actor BitwardenSync {
    public static let folderName = "Clipboard-Secrets"

    private let client: any BitwardenClient
    private let parker: SecretParker
    private var session: String?
    private var isTransferring = false
    private let idleTimeout: Duration
    private var idleLock: Task<Void, Never>?

    /// The vault locks again after `idleTimeout` without use, so the session key does not
    /// stay valid for days.
    public init(
        client: any BitwardenClient, parker: SecretParker, idleTimeout: Duration = .seconds(300)
    ) {
        self.client = client
        self.parker = parker
        self.idleTimeout = idleTimeout
    }

    public var isUnlocked: Bool { session != nil }

    /// What the menu shows. Never throws: a problem is a status too.
    public func status() async -> Result<BitwardenStatus, BitwardenError> {
        let used = session
        do {
            let status = try await client.status(session: used)
            // A vault unlocked elsewhere is no use without the session key.
            if status == .unlocked, used == nil { return .success(.locked) }
            // Not if a newer session was obtained while the command ran.
            if status != .unlocked, session == used { session = nil }
            return .success(status)
        } catch let error as BitwardenError {
            return .failure(error)
        } catch {
            return .failure(.commandFailed)
        }
    }

    /// Unlocks the vault, then moves everything that is waiting.
    public func unlock(masterPassword: String) async throws -> TransferReport {
        session = try await client.unlock(masterPassword: masterPassword)
        scheduleIdleLock()
        return try await transferPending()
    }

    public func lock() async {
        idleLock?.cancel()
        idleLock = nil
        guard let key = session else { return }
        session = nil
        try? await client.lock(session: key)
    }

    /// Moves every pending secret. A failure stops the run and leaves the rest parked, so
    /// nothing is lost; the report says what happened. Throws only for local storage errors.
    @discardableResult
    public func transferPending() async throws -> TransferReport {
        guard let key = session else {
            return TransferReport(
                transferred: 0, remaining: try parker.pending().count, failure: .locked)
        }
        guard !isTransferring else {
            return TransferReport(
                transferred: 0, remaining: try parker.pending().count, failure: .busy)
        }
        isTransferring = true
        defer { isTransferring = false }
        scheduleIdleLock()

        let pending = try parker.pending()
        var transferred = 0
        var failure: BitwardenError?
        if !pending.isEmpty {
            do {
                try await client.sync(session: key)
                let folder = try await client.folderID(named: Self.folderName, session: key)
                let existing = try await client.notes(inFolder: folder, session: key)
                for secret in pending {
                    do {
                        try await transfer(secret, folder: folder, existing: existing, session: key)
                        transferred += 1
                    } catch ParkingError.vaultItemMissing, ParkingError.notParked {
                        // Gone from the Keychain or taken back as "not a secret" meanwhile; the
                        // others can still be moved.
                        continue
                    } catch let error as BitwardenError where !error.endsTheRun {
                        // This secret stays parked; one bad secret must not block the rest.
                        failure = failure ?? error
                    }
                }
            } catch let error as BitwardenError {
                failure = error
            }
        }
        if failure == .locked, session == key { session = nil }
        // Also finishes what an interrupted run confirmed but did not delete.
        try parker.purgeTransferred()
        return TransferReport(
            transferred: transferred, remaining: try parker.pending().count, failure: failure)
    }

    private func transfer(
        _ secret: ParkedSecret, folder: String, existing: [BitwardenNote], session: String
    ) async throws {
        let value = try parker.reveal(id: secret.id)
        // A run that died after creating the note must not create it twice. A note with our
        // marker but another content is a conflict: the secret stays parked.
        let marked = existing.first { $0.clipkeepID == secret.vaultKey }
        if let marked, marked.notes != value { throw BitwardenError.unexpectedOutput }
        var itemID = marked?.id
        if marked == nil {
            let created = try await client.createSecureNote(
                name: secret.label, secret: value, clipkeepID: secret.vaultKey, folderID: folder,
                session: session)
            // Only what the server confirmed counts as transferred.
            guard created.notes == value else { throw BitwardenError.unexpectedOutput }
            itemID = created.id
        }
        try parker.markTransferred(id: secret.id, vaultItemID: itemID)
        try parker.deleteFromVault(id: secret.id)
    }

    /// Takes a secret back to a normal history entry ("not a secret"). If it already moved to
    /// Bitwarden, the value is fetched from there first, which needs an unlocked vault.
    public func markNotSecret(id: Int64) async throws {
        // Not while a transfer is moving this very secret.
        guard !isTransferring else { throw BitwardenError.busy }
        do {
            try parker.markNotSecret(id: id)
        } catch ParkingError.vaultItemMissing {
            let value = try await retrieve(secretID: id)
            try parker.markNotSecret(id: id, value: value)
        }
    }

    /// The secret, from the Keychain while it is still parked, otherwise from Bitwarden.
    public func retrieve(secretID: Int64) async throws -> String {
        guard let secret = try parker.secret(id: secretID) else { throw ParkingError.notFound }
        if secret.state == .parked, let value = try? parker.reveal(id: secretID) { return value }
        guard secret.state == .transferred || secret.state == .deleted else {
            throw ParkingError.vaultItemMissing
        }
        guard let key = session else { throw BitwardenError.locked }
        scheduleIdleLock()
        do {
            // Direct by id; a note that was moved, renamed or never got an id is found by its
            // marker instead.
            if let itemID = secret.vaultItemID,
                let note = try? await client.note(id: itemID, session: key),
                note.clipkeepID == secret.vaultKey, let value = note.notes
            {
                return value
            }
            let folder = try await client.folderID(named: Self.folderName, session: key)
            let notes = try await client.notes(inFolder: folder, session: key)
            guard let value = notes.first(where: { $0.clipkeepID == secret.vaultKey })?.notes else {
                throw ParkingError.vaultItemMissing
            }
            return value
        } catch BitwardenError.locked {
            if session == key { session = nil }
            throw BitwardenError.locked
        }
    }
}

extension BitwardenSync {
    private func scheduleIdleLock() {
        idleLock?.cancel()
        let timeout = idleTimeout
        idleLock = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.lock()
        }
    }
}

extension BitwardenError {
    /// Whether the error concerns the whole run rather than one secret.
    fileprivate var endsTheRun: Bool {
        switch self {
        case .locked, .loggedOut, .offline, .timedOut, .notInstalled, .busy: true
        case .invalidMasterPassword, .unexpectedOutput, .commandFailed: false
        }
    }
}

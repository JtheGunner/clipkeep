import Foundation

public struct TransferReport: Sendable, Equatable {
    /// Secrets now in Bitwarden and removed from the Keychain.
    public let transferred: Int
    /// Secrets still parked in the Keychain.
    public let remaining: Int
    public let failure: BitwardenError?
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

    public init(client: any BitwardenClient, parker: SecretParker) {
        self.client = client
        self.parker = parker
    }

    public var isUnlocked: Bool { session != nil }

    /// What the menu shows. Never throws: a problem is a status too.
    public func status() async -> Result<BitwardenStatus, BitwardenError> {
        do {
            let status = try await client.status(session: session)
            // A vault unlocked elsewhere is no use without the session key.
            if status == .unlocked, session == nil { return .success(.locked) }
            if status != .unlocked { session = nil }
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
        return try await transferPending()
    }

    public func lock() async {
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
                    } catch ParkingError.vaultItemMissing {
                        // Its Keychain item vanished, so it cannot be moved; the others can.
                        continue
                    }
                }
            } catch let error as BitwardenError {
                failure = error
            }
        }
        if failure == .locked { session = nil }
        // Also finishes what an interrupted run confirmed but did not delete.
        try parker.purgeTransferred()
        return TransferReport(
            transferred: transferred, remaining: try parker.pending().count, failure: failure)
    }

    private func transfer(
        _ secret: ParkedSecret, folder: String, existing: [BitwardenNote], session: String
    ) async throws {
        let value = try parker.reveal(id: secret.id)
        // A run that died after creating the note must not create it twice.
        let alreadyThere = existing.contains {
            $0.clipkeepID == secret.vaultKey && $0.notes == value
        }
        if !alreadyThere {
            let created = try await client.createSecureNote(
                name: secret.label, secret: value, clipkeepID: secret.vaultKey, folderID: folder,
                session: session)
            // Only what the server confirmed counts as transferred.
            guard created.notes == value else { throw BitwardenError.unexpectedOutput }
        }
        try parker.markTransferred(id: secret.id)
        try parker.deleteFromVault(id: secret.id)
    }

    /// The secret, from the Keychain while it is still parked, otherwise from Bitwarden.
    public func retrieve(secretID: Int64) async throws -> String {
        guard let secret = try parker.secret(id: secretID) else { throw ParkingError.notFound }
        if secret.state == .parked, let value = try? parker.reveal(id: secretID) { return value }
        guard secret.state == .transferred || secret.state == .deleted else {
            throw ParkingError.vaultItemMissing
        }
        guard let key = session else { throw BitwardenError.locked }
        do {
            let folder = try await client.folderID(named: Self.folderName, session: key)
            let notes = try await client.notes(inFolder: folder, session: key)
            guard let value = notes.first(where: { $0.clipkeepID == secret.vaultKey })?.notes else {
                throw ParkingError.vaultItemMissing
            }
            return value
        } catch BitwardenError.locked {
            session = nil
            throw BitwardenError.locked
        }
    }
}

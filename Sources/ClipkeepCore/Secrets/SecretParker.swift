import CryptoKit
import Foundation

public enum ParkedSecretState: String, Sendable, Equatable {
    case parked
    /// Confirmed to be in the password manager; the Keychain copy may now go.
    case transferred
    /// Removed from the Keychain after a confirmed transfer.
    case deleted
    /// The Keychain item vanished before it was transferred.
    case lost
}

public struct ParkedSecret: Sendable, Equatable {
    public let id: Int64
    public let contentID: Int64?
    public let kind: SecretKind
    /// The placeholder text shown in the history.
    public let label: String
    public let state: ParkedSecretState
    public let parkedAt: Date
    public let transferredAt: Date?
    public let deletedAt: Date?
    let vaultKey: String
}

public enum ParkingError: Error, Equatable {
    case notFound
    case notParked
    case notTransferred
    case vaultItemMissing
}

/// Parks detected secrets in a vault (the Keychain) and leaves only a placeholder in the history.
/// The database never sees the secret: not in a table, not in the full-text index.
public struct SecretParker: SecretSink {
    /// Serialises parking and reconciling within the process.
    private static let lock = NSLock()
    /// Vault entry holding the key of the repeat-copy fingerprints; not a secret to transfer.
    static let fingerprintKeyName = "fingerprint-key"

    private let database: Database
    private let store: ContentStore
    private let vault: any SecretVault
    private let detector: SecretDetector
    private let onError: @Sendable (Error) -> Void

    public init(
        database: Database, store: ContentStore, vault: any SecretVault,
        detector: SecretDetector = SecretDetector(),
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.database = database
        self.store = store
        self.vault = vault
        self.detector = detector
        self.onError = onError
    }

    // MARK: - SecretSink

    public func handle(secret text: String, context: CopyContext, copiedAt: Date) {
        do {
            try park(text, context: context, copiedAt: copiedAt)
        } catch {
            // The secret stays out of the history even when parking fails.
            onError(error)
        }
    }

    private func park(_ text: String, context: CopyContext, copiedAt: Date) throws {
        // Parking and reconciling never overlap, so a Keychain item that is still being
        // registered is never mistaken for a leftover.
        try Self.lock.withLock {
            let kind =
                detector.detect(in: text).max { $0.confidence < $1.confidence }?.kind
                ?? .highEntropyToken
            let fingerprint = try fingerprint(of: text)

            // Copying the same secret again adds a copy to its placeholder instead of a new entry.
            if let existing = try parkedSecret(withFingerprint: fingerprint) {
                _ = try store.record(
                    text: existing.label, copiedAt: copiedAt, context: context, kind: .secret
                ) { connection, recorded in
                    try connection.execute(
                        "UPDATE parked_secrets SET content_id = ? WHERE id = ?",
                        [.int(recorded.contentID), .int(existing.id)])
                }
                return
            }

            let key = UUID().uuidString
            let label = Self.label(kind: kind, context: context, copiedAt: copiedAt)
            try vault.store(text, key: key)
            do {
                // Placeholder, copy event and parked row commit together or not at all.
                _ = try store.record(
                    text: label, copiedAt: copiedAt, context: context, kind: .secret
                ) { connection, recorded in
                    try connection.execute(
                        """
                        INSERT INTO parked_secrets
                            (vault_key, fingerprint, content_id, kind, label, parked_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(key), .text(fingerprint), .int(recorded.contentID),
                            .text(kind.rawValue), .text(label), SQLValue(copiedAt),
                        ])
                }
            } catch {
                // No Keychain item without a row; the failed transaction left no placeholder.
                try? vault.delete(key: key)
                throw error
            }
        }
    }

    private func parkedSecret(withFingerprint fingerprint: String) throws -> ParkedSecret? {
        try secrets(
            where: "state = 'parked' AND fingerprint = ?", [.text(fingerprint)], limit: 1
        ).first
    }

    /// Keyed hash of the secret. The key stays in the Keychain, so the stored value cannot be
    /// used to guess the secret offline.
    private func fingerprint(of text: String) throws -> String {
        let key = try fingerprintKey()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func fingerprintKey() throws -> SymmetricKey {
        if let stored = try vault.read(key: Self.fingerprintKeyName), let data = Data(hex: stored) {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        let hex = fresh.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        try vault.store(hex, key: Self.fingerprintKeyName)
        return fresh
    }

    // MARK: - Reading

    /// Secrets waiting to be moved to the password manager, oldest first.
    public func pending() throws -> [ParkedSecret] {
        try secrets(where: "state = 'parked'", [], limit: 10_000, ascending: true)
    }

    public func secret(id: Int64) throws -> ParkedSecret? {
        try secrets(where: "id = ?", [.int(id)], limit: 1).first
    }

    /// The parked value, for the transfer to the password manager.
    public func reveal(id: Int64) throws -> String {
        guard let secret = try secret(id: id) else { throw ParkingError.notFound }
        guard secret.state == .parked || secret.state == .transferred else {
            throw ParkingError.vaultItemMissing
        }
        guard let value = try vault.read(key: secret.vaultKey) else {
            throw ParkingError.vaultItemMissing
        }
        return value
    }

    // MARK: - State changes

    /// Records that the password manager confirmed it holds the secret.
    public func markTransferred(id: Int64, at date: Date = Date()) throws {
        try database.write { connection in
            try connection.execute(
                "UPDATE parked_secrets SET state = 'transferred', transferred_at = ? WHERE id = ? AND state = 'parked'",
                [SQLValue(date), .int(id)])
            if connection.changedRowCount == 0 {
                let exists = try !connection.query(
                    "SELECT 1 FROM parked_secrets WHERE id = ?", [.int(id)]
                ) { _ in 1 }.isEmpty
                throw exists ? ParkingError.notParked : ParkingError.notFound
            }
        }
    }

    /// Removes a confirmed secret from the Keychain. Refuses anything not transferred yet.
    public func deleteFromVault(id: Int64, at date: Date = Date()) throws {
        guard let secret = try secret(id: id) else { throw ParkingError.notFound }
        guard secret.state == .transferred else { throw ParkingError.notTransferred }
        try vault.delete(key: secret.vaultKey)
        try database.write { connection in
            try connection.execute(
                "UPDATE parked_secrets SET state = 'deleted', deleted_at = ? WHERE id = ?",
                [SQLValue(date), .int(id)])
        }
    }

    /// Deletes every transferred secret from the Keychain; returns how many were removed.
    @discardableResult
    public func purgeTransferred(at date: Date = Date()) throws -> Int {
        let confirmed = try secrets(where: "state = 'transferred'", [], limit: 10_000)
        for secret in confirmed { try deleteFromVault(id: secret.id, at: date) }
        return confirmed.count
    }

    /// Brings database and Keychain back in line, for example after a crash. Keychain items
    /// without a row are adopted as pending secrets (they may be the only copy), never deleted.
    /// Rows whose item is gone become lost, or deleted if the transfer was confirmed. Run it
    /// before capture starts; a failure for one item does not stop the others.
    @discardableResult
    public func reconcile(now: Date = Date()) throws -> (adopted: Int, lost: Int) {
        try Self.lock.withLock {
            let known = Set(
                try database.read { connection in
                    try connection.query("SELECT vault_key FROM parked_secrets") { $0.text(0) }
                })
            let vaultKeys = Set(try vault.keys())
            var adopted = 0
            for key in vaultKeys.subtracting(known) where key != Self.fingerprintKeyName {
                guard let value = try? vault.read(key: key),
                    let fingerprint = try? fingerprint(of: value)
                else { continue }
                let kind =
                    detector.detect(in: value).max { $0.confidence < $1.confidence }?.kind
                    ?? .highEntropyToken
                let label = "Wiederhergestelltes Secret · \(Self.typeName(kind))"
                let inserted = try? database.write { connection in
                    try connection.execute(
                        """
                        INSERT INTO parked_secrets (vault_key, fingerprint, kind, label, parked_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        [
                            .text(key), .text(fingerprint), .text(kind.rawValue), .text(label),
                            SQLValue(now),
                        ])
                }
                if inserted != nil { adopted += 1 }
            }

            var lost = 0
            for secret in try secrets(
                where: "state IN ('parked', 'transferred')", [], limit: 10_000)
            where !vaultKeys.contains(secret.vaultKey) {
                // A transferred secret whose item is gone was deleted; only a parked one is lost.
                let state = secret.state == .transferred ? "deleted" : "lost"
                try database.write { connection in
                    try connection.execute(
                        "UPDATE parked_secrets SET state = ?, deleted_at = ? WHERE id = ?",
                        [
                            .text(state), state == "deleted" ? SQLValue(now) : .null,
                            .int(secret.id),
                        ])
                }
                if state == "lost" { lost += 1 }
            }
            return (adopted, lost)
        }
    }

    // MARK: - Helpers

    private func secrets(
        where condition: String, _ parameters: [SQLValue], limit: Int, ascending: Bool = false
    ) throws -> [ParkedSecret] {
        try database.read { connection in
            try connection.query(
                """
                SELECT id, content_id, kind, label, state, parked_at, transferred_at, deleted_at,
                    vault_key
                FROM parked_secrets WHERE \(condition) ORDER BY id \(ascending ? "ASC" : "DESC") LIMIT ?
                """,
                parameters + [.int(Int64(limit))]
            ) { row in
                ParkedSecret(
                    id: row.int(0), contentID: row.isNull(1) ? nil : row.int(1),
                    kind: SecretKind(rawValue: row.text(2)) ?? .highEntropyToken,
                    label: row.text(3),
                    state: ParkedSecretState(rawValue: row.text(4)) ?? .lost,
                    parkedAt: Date(timeIntervalSince1970: row.double(5)),
                    transferredAt: row.isNull(6) ? nil : Date(timeIntervalSince1970: row.double(6)),
                    deletedAt: row.isNull(7) ? nil : Date(timeIntervalSince1970: row.double(7)),
                    vaultKey: row.text(8))
            }
        }
    }

    /// Placeholder text: type, website or app, and time. Never any part of the secret.
    static func label(kind: SecretKind, context: CopyContext, copiedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_CH")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        var parts = [typeName(kind)]
        if let url = context.url, let host = SessionService.host(of: url) {
            parts.append(host)
        } else if let app = context.appName {
            parts.append(app)
        }
        parts.append(formatter.string(from: copiedAt))
        return parts.joined(separator: " · ") + " → gesichert"
    }

    static func typeName(_ kind: SecretKind) -> String {
        switch kind {
        case .openAIKey: "OpenAI API-Key"
        case .anthropicKey: "Anthropic API-Key"
        case .githubToken: "GitHub-Token"
        case .awsAccessKeyID: "AWS Access Key"
        case .slackToken: "Slack-Token"
        case .gitlabToken: "GitLab-Token"
        case .stripeKey: "Stripe-Key"
        case .googleAPIKey: "Google API-Key"
        case .jwt: "JWT"
        case .privateKey: "Privater Schlüssel"
        case .keyValueSecret: "Zugangsdaten"
        case .highEntropyToken: "Geheimer Token"
        }
    }
}

extension Data {
    fileprivate init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

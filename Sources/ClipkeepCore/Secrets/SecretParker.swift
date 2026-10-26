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
    private static let duplicateCheckLimit = 50

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
        let kind =
            detector.detect(in: text).max { $0.confidence < $1.confidence }?.kind
            ?? .highEntropyToken
        // Copying the same secret again adds a copy to its placeholder instead of a new entry.
        if let existing = try parkedDuplicate(of: text, kind: kind) {
            _ = try store.record(text: existing.label, copiedAt: copiedAt, context: context)
            return
        }

        let key = UUID().uuidString
        let label = Self.label(kind: kind, context: context, copiedAt: copiedAt)
        try vault.store(text, key: key)
        var placeholder: RecordedCopy?
        do {
            let recorded = try store.record(text: label, copiedAt: copiedAt, context: context)
            placeholder = recorded
            try database.write { connection in
                try connection.execute(
                    "UPDATE contents SET kind = ? WHERE id = ?",
                    [.text(ContentKind.secret.rawValue), .int(recorded.contentID)])
                try connection.execute(
                    """
                    INSERT INTO parked_secrets (vault_key, content_id, kind, label, parked_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(key), .int(recorded.contentID), .text(kind.rawValue), .text(label),
                        SQLValue(copiedAt),
                    ])
            }
        } catch {
            // Nothing may claim "gesichert" without a Keychain item behind it, and no Keychain
            // item may exist without a row.
            try? vault.delete(key: key)
            if let placeholder, placeholder.isNewContent {
                try? database.write { connection in
                    try connection.execute(
                        "DELETE FROM contents WHERE id = ?", [.int(placeholder.contentID)])
                }
            }
            throw error
        }
    }

    private func parkedDuplicate(of text: String, kind: SecretKind) throws -> ParkedSecret? {
        let candidates = try secrets(
            where: "state = 'parked' AND kind = ?", [.text(kind.rawValue)],
            limit: Self.duplicateCheckLimit)
        for candidate in candidates where try vault.read(key: candidate.vaultKey) == text {
            return candidate
        }
        return nil
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

    /// Brings database and Keychain back in line, for example after a crash between the two
    /// steps. Removes Keychain items without a row and marks parked rows whose item is gone as
    /// lost. Run it before capture starts.
    @discardableResult
    public func reconcile() throws -> (orphansRemoved: Int, lost: Int) {
        let known = try database.read { connection in
            try connection.query("SELECT vault_key FROM parked_secrets") { $0.text(0) }
        }
        let vaultKeys = Set(try vault.keys())
        let orphans = vaultKeys.subtracting(known)
        for key in orphans { try vault.delete(key: key) }

        var lost = 0
        for secret in try secrets(where: "state IN ('parked', 'transferred')", [], limit: 10_000)
        where !vaultKeys.contains(secret.vaultKey) {
            try database.write { connection in
                try connection.execute(
                    "UPDATE parked_secrets SET state = 'lost' WHERE id = ?", [.int(secret.id)])
            }
            lost += 1
        }
        return (orphans.count, lost)
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
                    state: ParkedSecretState(rawValue: row.text(4)) ?? .parked,
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
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        var parts = [typeName(kind)]
        if let url = context.url, let host = SessionService.host(of: url) {
            parts.append(host)
        } else if let app = context.appName {
            parts.append(app)
        }
        parts.append(formatter.string(from: copiedAt))
        return parts.joined(separator: " · ") + " → gesichert"
    }

    private static func typeName(_ kind: SecretKind) -> String {
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

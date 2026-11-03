import Foundation
import Security

public enum SecretVaultError: Error, Equatable {
    case keychain(Int32)
    case corruptValue
}

/// Safe storage for parked secrets, outside the database.
public protocol SecretVault: Sendable {
    func store(_ secret: String, key: String) throws
    func read(key: String) throws -> String?
    /// Deleting a missing key is not an error.
    func delete(key: String) throws
    func keys() throws -> [String]
}

/// Keeps all parked secrets in one generic password item of the macOS Keychain.
///
/// One item means one access list: macOS asks for the login password at most once and
/// "Always Allow" covers every secret. With an item per secret the transfer to Bitwarden
/// prompted once per secret. The item is read once and then served from memory, so create a
/// single instance per service and share it.
///
/// Earlier versions kept one item per secret under `legacyService`. They are moved into the
/// consolidated item the first time the vault is used and removed afterwards.
public final class KeychainSecretVault: SecretVault, @unchecked Sendable {
    public static let defaultService = AppInfo.bundleIdentifier + ".parked-secrets"
    private static let account = "all-secrets"

    private let legacyService: String
    private let service: String
    private let lock = NSLock()
    private var cache: [String: String]?
    private var itemExists = false

    public init(service legacyService: String = defaultService) {
        self.legacyService = legacyService
        self.service = legacyService + ".v2"
    }

    public func store(_ secret: String, key: String) throws {
        try mutate { secrets in
            guard secrets[key] == nil else {
                throw SecretVaultError.keychain(errSecDuplicateItem)
            }
            secrets[key] = secret
        }
    }

    public func read(key: String) throws -> String? {
        try lock.withLock { try loaded()[key] }
    }

    public func delete(key: String) throws {
        try mutate { _ = $0.removeValue(forKey: key) }
    }

    public func keys() throws -> [String] {
        try lock.withLock { Array(try loaded().keys) }
    }

    // MARK: - Consolidated item

    /// Applies `change` to a copy and keeps it only once the Keychain accepted it.
    private func mutate(_ change: (inout [String: String]) throws -> Void) throws {
        try lock.withLock {
            var secrets = try loaded()
            let before = secrets
            try change(&secrets)
            guard secrets != before else { return }
            try save(secrets)
            cache = secrets
        }
    }

    /// The secrets, read from the Keychain on first use. Call with the lock held.
    private func loaded() throws -> [String: String] {
        if let cache { return cache }
        var secrets = try loadConsolidated()
        let legacy = migrateLegacy(into: &secrets)
        if !legacy.isEmpty {
            try save(secrets)
            for account in legacy { removeLegacyItem(account) }
        }
        cache = secrets
        return secrets
    }

    private func loadConsolidated() throws -> [String: String] {
        var query = consolidatedQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            itemExists = false
            return [:]
        }
        guard status == errSecSuccess else { throw SecretVaultError.keychain(status) }
        guard let data = result as? Data,
            let secrets = try? JSONDecoder().decode([String: String].self, from: data)
        else { throw SecretVaultError.corruptValue }
        itemExists = true
        return secrets
    }

    private func save(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        let status: OSStatus
        if itemExists {
            status = SecItemUpdate(
                consolidatedQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var attributes = consolidatedQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretVaultError.keychain(status) }
        itemExists = true
    }

    private var consolidatedQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    // MARK: - Migration of per-secret items

    /// Copies the per-secret items into `secrets` and returns the accounts that were copied.
    /// An item that cannot be read (for example the user denied access) stays where it is
    /// and is tried again next time.
    private func migrateLegacy(into secrets: inout [String: String]) -> [String] {
        var migrated: [String] = []
        for account in legacyAccounts() {
            guard let value = readLegacyItem(account) else { continue }
            // A key already present came from the consolidated item and wins.
            if secrets[account] == nil { secrets[account] = value }
            migrated.append(account)
        }
        return migrated
    }

    private func legacyAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return []
        }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func readLegacyItem(_ account: String) -> String? {
        var query = legacyQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func removeLegacyItem(_ account: String) {
        SecItemDelete(legacyQuery(account) as CFDictionary)
    }

    private func legacyQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ]
    }
}

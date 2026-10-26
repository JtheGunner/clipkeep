import Foundation
import Security

public enum KeyStoreError: Error, Equatable {
    case randomGenerationFailed(Int32)
    case keychain(Int32)
    case corruptKey
}

/// Provides the 32-byte database key. The key never lives in the database directory.
public protocol DatabaseKeyStore: Sendable {
    func loadOrCreateKey() throws -> Data
}

/// Stores the key as a generic password item in the macOS Keychain.
public struct KeychainDatabaseKeyStore: DatabaseKeyStore {
    private let service: String
    private let account: String

    public init(service: String = AppInfo.bundleIdentifier, account: String = "database-key") {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> Data {
        if let key = try load() { return key }
        return try create()
    }

    /// Removes the key. Only for tests and a future "reset" feature.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        guard let key = result as? Data, key.count == 32 else { throw KeyStoreError.corruptKey }
        return key
    }

    private func create() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw KeyStoreError.randomGenerationFailed(randomStatus)
        }
        let key = Data(bytes)

        var attributes = baseQuery
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load() {
            // Another process created the key between our lookup and insert; use theirs.
            return existing
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        return key
    }
}

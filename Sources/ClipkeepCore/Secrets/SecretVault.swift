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

/// Keeps parked secrets as generic password items in the macOS Keychain.
public struct KeychainSecretVault: SecretVault {
    public static let defaultService = AppInfo.bundleIdentifier + ".parked-secrets"

    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    public func store(_ secret: String, key: String) throws {
        var attributes = baseQuery(key)
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretVaultError.keychain(status) }
    }

    public func read(key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretVaultError.keychain(status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw SecretVaultError.corruptValue
        }
        return secret
    }

    public func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretVaultError.keychain(status)
        }
    }

    public func keys() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SecretVaultError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

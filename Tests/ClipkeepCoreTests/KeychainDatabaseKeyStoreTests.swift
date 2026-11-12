import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct KeychainDatabaseKeyStoreTests {
    @Test func createsThenReturnsTheSameKey() throws {
        let store = KeychainDatabaseKeyStore(
            service: "li.wuermli.clipkeep.tests.\(UUID().uuidString)", account: "test-key")
        defer { try? store.delete() }

        let first = try store.loadOrCreateKey()
        let second = try store.loadOrCreateKey()

        #expect(first.count == 32)
        #expect(first == second)
    }

    @Test func loadExistingKeyNeverCreatesOne() throws {
        let store = KeychainDatabaseKeyStore(
            service: "li.wuermli.clipkeep.tests.\(UUID().uuidString)", account: "test-key")
        defer { try? store.delete() }

        #expect(throws: KeyStoreError.missingKey) { try store.loadExistingKey() }
        // Nothing was stored by the failed lookup.
        #expect(throws: KeyStoreError.missingKey) { try store.loadExistingKey() }

        let created = try store.loadOrCreateKey()
        #expect(try store.loadExistingKey() == created)
    }

    @Test func differentServicesGetDifferentKeys() throws {
        let storeA = KeychainDatabaseKeyStore(
            service: "li.wuermli.clipkeep.tests.\(UUID().uuidString)", account: "k")
        let storeB = KeychainDatabaseKeyStore(
            service: "li.wuermli.clipkeep.tests.\(UUID().uuidString)", account: "k")
        defer {
            try? storeA.delete()
            try? storeB.delete()
        }

        #expect(try storeA.loadOrCreateKey() != storeB.loadOrCreateKey())
    }
}

import ClipkeepCore
import Foundation

/// Opens the encrypted history database in Application Support. The key lives in the Keychain.
enum AppDatabase {
    static func open(keyStore: any DatabaseKeyStore = KeychainDatabaseKeyStore()) throws -> Database
    {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true
        ).appendingPathComponent("Clipkeep", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its old permissions unless they are set again.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let database = try Database(
            path: directory.appendingPathComponent("clipkeep.db").path,
            key: try keyStore.loadOrCreateKey())
        try Schema.migrator.migrate(database)
        return database
    }
}

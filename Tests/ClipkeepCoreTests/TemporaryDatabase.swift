import Foundation

@testable import ClipkeepCore

/// A throwaway encrypted database in a unique temp directory.
struct TemporaryDatabase {
    let directory: URL
    let path: String
    let key: Data

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("test.db").path
        key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    func open(migrated: Bool = true) throws -> Database {
        let database = try Database(path: path, key: key)
        if migrated { try Schema.migrator.migrate(database) }
        return database
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

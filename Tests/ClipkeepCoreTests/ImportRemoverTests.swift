import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct ImportRemoverTests {
    private let end = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let importer: TextImporter
        let remover: ImportRemover

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            importer = TextImporter(database: database, secretSink: nil)
            remover = ImportRemover(database: database)
        }

        func visibleTexts() throws -> [String] {
            try database.read {
                try $0.query("SELECT text FROM contents WHERE deleted_at IS NULL ORDER BY id") {
                    $0.text(0)
                }
            }
        }
    }

    @Test func noImportsMeansAnEmptyList() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        #expect(try fixture.remover.imports().isEmpty)
    }

    @Test func listsEachImportedFileWithItsEntryCount() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.importer.run(
            text: "a one\n---\na two\n---\na three", source: "a.txt", endingAt: end)
        _ = try fixture.importer.run(
            text: "b one", source: "b.txt", endingAt: end.addingTimeInterval(86_400))

        let imports = try fixture.remover.imports()

        #expect(imports.map(\.source) == ["b.txt", "a.txt"])
        #expect(imports.map(\.entryCount) == [1, 3])
    }

    @Test func removingAnImportHidesItsEntriesOnly() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.importer.run(
            text: "a one\n---\na two", source: "a.txt", endingAt: end)
        _ = try fixture.importer.run(text: "b one", source: "b.txt", endingAt: end)

        let removed = try fixture.remover.remove(source: "a.txt")

        #expect(removed.count == 2)
        #expect(try fixture.visibleTexts() == ["b one"])
        #expect(try fixture.remover.imports().map(\.source) == ["b.txt"])
    }

    @Test func anEntryThatExistedBeforeTheImportStays() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let store = ContentStore(database: fixture.database)
        _ = try store.record(
            text: "shared note", copiedAt: end.addingTimeInterval(-86_400), context: CopyContext())
        _ = try fixture.importer.run(
            text: "shared note\n---\nonly in file", source: "a.txt", endingAt: end)

        let removed = try fixture.remover.remove(source: "a.txt")

        #expect(removed.count == 1)
        #expect(try fixture.visibleTexts() == ["shared note"])
    }

    @Test func removingTwiceDoesNothingTheSecondTime() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.importer.run(text: "a one", source: "a.txt", endingAt: end)
        _ = try fixture.remover.remove(source: "a.txt")

        #expect(try fixture.remover.remove(source: "a.txt").isEmpty)
    }

    @Test func restoringBringsTheEntriesBack() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.importer.run(
            text: "a one\n---\na two", source: "a.txt", endingAt: end)
        let removed = try fixture.remover.remove(source: "a.txt")

        try fixture.remover.restore(removed)

        #expect(try fixture.visibleTexts() == ["a one", "a two"])
        #expect(try fixture.remover.imports().map(\.entryCount) == [2])
    }

    @Test func aLiveCopyIsNeverPartOfAnImport() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let store = ContentStore(database: fixture.database)
        _ = try store.record(text: "live copy", copiedAt: end, context: CopyContext())

        #expect(try fixture.remover.imports().isEmpty)
        #expect(try fixture.remover.remove(source: "live copy").isEmpty)
        #expect(try fixture.visibleTexts() == ["live copy"])
    }
}

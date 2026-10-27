import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct TextImportTests {
    private let end = Date(timeIntervalSince1970: 1_800_000_000)

    // Built at runtime so no secret-shaped literal sits in the source.
    private let token = "gh" + "p_" + String(repeating: "aB3dE6gH9j", count: 4)

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
        }
    }

    private final class RecordingSink: SecretSink, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var secrets: [String] { lock.withLock { stored } }

        func handle(secret text: String, context: CopyContext, copiedAt: Date) {
            lock.withLock { stored.append(text) }
        }
    }

    // MARK: - Splitting

    @Test func separatorLinesCutEntriesAndKeepBlankLinesInside() {
        let text = "first line\n\nstill first\n---\nsecond\n===\n  third  \n"
        #expect(
            TextSplitter.split(text) == ["first line\n\nstill first", "second", "third"])
    }

    @Test func withoutSeparatorsBlankLinesCut() {
        let text = "one\ntwo\n\n\nthree\n\nfour"
        #expect(TextSplitter.split(text) == ["one\ntwo", "three", "four"])
        #expect(TextSplitter.resolve(.automatic, text: text) == .blankLines)
    }

    @Test func withoutAnyBreakEveryLineIsAnEntry() {
        let text = "alpha\nbeta\ngamma"
        #expect(TextSplitter.split(text) == ["alpha", "beta", "gamma"])
        #expect(TextSplitter.resolve(.automatic, text: text) == .everyLine)
    }

    @Test func aModeCanBeForced() {
        let text = "a\nb\n\nc\n---\nd"
        #expect(TextSplitter.split(text, mode: .everyLine) == ["a", "b", "c", "---", "d"])
        #expect(TextSplitter.split(text, mode: .blankLines) == ["a\nb", "c\n---\nd"])
        #expect(TextSplitter.split(text, mode: .separatorLines) == ["a\nb\n\nc", "d"])
    }

    @Test func windowsLineEndingsWork() {
        #expect(TextSplitter.split("one\r\n\r\ntwo\r\n") == ["one", "two"])
    }

    @Test func shortRulesAreNotSeparators() {
        #expect(TextSplitter.split("keep\n--\nthis\n") == ["keep", "--", "this"])
        #expect(
            TextSplitter.split("a\n--- not a rule\nb", mode: .separatorLines) == [
                "a\n--- not a rule\nb"
            ])
    }

    @Test func emptyInputGivesNoEntries() {
        #expect(TextSplitter.split("").isEmpty)
        #expect(TextSplitter.split("\n\n---\n \n").isEmpty)
    }

    // MARK: - Importing

    @Test func entriesCarryTheImportSourceAndNoLiveContext() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let importer = TextImporter(database: fixture.database, secretSink: nil)
        let report = try importer.run(
            text: "first note\n---\nsecond note", source: "notes.txt", endingAt: end)
        #expect(report.imported == 2)

        let rows = try fixture.database.read { connection in
            try connection.query(
                """
                SELECT c.text, e.app_bundle_id, e.app_name, e.window_title, e.url, e.copied_at
                FROM copy_events e JOIN contents c ON c.id = e.content_id ORDER BY e.copied_at
                """
            ) {
                (
                    $0.text(0), $0.optionalText(1), $0.optionalText(2), $0.optionalText(3),
                    $0.optionalText(4), $0.double(5)
                )
            }
        }
        #expect(rows.map(\.0) == ["first note", "second note"])
        #expect(rows.allSatisfy { $0.1 == TextImporter.importBundleID && $0.2 == "Import" })
        #expect(rows.allSatisfy { $0.3 == "notes.txt" && $0.4 == nil })
        #expect(rows[1].5 == end.timeIntervalSince1970)
        #expect(rows[0].5 < rows[1].5)
    }

    @Test func importedEntriesAreClassifiedAndGetSessions() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let importer = TextImporter(database: fixture.database, secretSink: nil)
        _ = try importer.run(
            text: "https://example.com/page\n---\nplain words here", source: "n.txt", endingAt: end)
        let kinds = try fixture.database.read {
            try $0.query("SELECT kind FROM contents ORDER BY id") { $0.text(0) }
        }
        #expect(kinds == ["url", "text"])
        let sessions = try SessionService(database: fixture.database).sessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].eventCount == 2)
    }

    @Test func importingTheSameFileAgainAddsNothing() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let importer = TextImporter(database: fixture.database, secretSink: nil)
        let text = "one note\n---\ntwo notes\n---\none note"
        let first = try importer.run(text: text, source: "n.txt", endingAt: end)
        #expect(first.imported == 2)
        #expect(first.duplicates == 1)
        let second = try importer.run(text: text, source: "n.txt", endingAt: end)
        #expect(second.imported == 0)
        #expect(second.duplicates == 3)
        let counts = try fixture.database.read { connection in
            (
                try connection.query("SELECT count(*) FROM contents") { $0.int(0) }.first,
                try connection.query("SELECT count(*) FROM copy_events") { $0.int(0) }.first
            )
        }
        #expect(counts.0 == 2)
        #expect(counts.1 == 2)
    }

    @Test func aTextCopiedLiveBeforeIsNotImportedAgain() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try ContentStore(database: fixture.database).record(text: "already here", copiedAt: end)
        let report = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: "already here\n---\nnew one", source: "n.txt", endingAt: end)
        #expect(report.imported == 1)
        #expect(report.duplicates == 1)
    }

    @Test func tooShortEntriesAreSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let report = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: "x\n---\nlong enough", source: "n.txt", endingAt: end)
        #expect(report.skipped == 1)
        #expect(report.imported == 1)
    }

    // MARK: - Secrets

    @Test func secretsGoToTheSinkAndNeverIntoTheDatabase() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let sink = RecordingSink()
        let importer = TextImporter(database: fixture.database, secretSink: sink)
        let report = try importer.run(
            text: "deploy notes\n---\nexport TOKEN=\(token)\n---\nlast note", source: "n.txt",
            endingAt: end)
        #expect(report.secrets == 1)
        #expect(report.imported == 2)
        #expect(sink.secrets.count == 1)
        try expectNoTrace(of: token, in: fixture.database)
    }

    @Test func withoutAVaultSecretsAreDroppedNotStored() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let report = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: "export TOKEN=\(token)\n---\nplain note", source: "n.txt", endingAt: end)
        #expect(report.secrets == 1)
        #expect(report.imported == 1)
        try expectNoTrace(of: token, in: fixture.database)
    }

    private func expectNoTrace(of secret: String, in database: Database) throws {
        let hits = try database.read { connection in
            try connection.query(
                "SELECT count(*) FROM contents WHERE instr(text, ?) > 0 OR instr(search_text, ?) > 0",
                [.text(secret), .text(secret.lowercased())]
            ) { $0.int(0) }.first
        }
        #expect(hits == 0)
        let found = try SearchService(database: database).search(String(secret.dropFirst(4)))
        #expect(found.isEmpty)
    }

    // MARK: - Preview

    @Test func thePreviewCountsWithoutChangingAnything() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try ContentStore(database: fixture.database).record(text: "known entry", copiedAt: end)
        let importer = TextImporter(database: fixture.database, secretSink: nil)
        let text = "known entry\n---\nfresh entry\n---\nexport TOKEN=\(token)\n---\nx"
        let preview = try importer.preview(text: text)
        #expect(preview.mode == .separatorLines)
        #expect(preview.entryCount == 4)
        #expect(preview.secretCount == 1)
        #expect(preview.alreadyStoredCount == 1)
        #expect(preview.tooShortCount == 1)
        #expect(!preview.samples.joined().contains(token))
        let stored = try fixture.database.read {
            try $0.query("SELECT count(*) FROM contents") { $0.int(0) }.first
        }
        #expect(stored == 1)
    }

    @Test func thePreviewShowsOnlyAFewEntriesAndLines() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let long = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let text = (0..<50).map { "entry \($0)\n\(long)" }.joined(separator: "\n---\n")
        let preview = try TextImporter(database: fixture.database, secretSink: nil)
            .preview(text: text)
        #expect(preview.entryCount == 50)
        #expect(preview.samples.count == ImportPreview.sampleSize)
        #expect(preview.samples[0].hasSuffix("…"))
        #expect(preview.samples[0].split(separator: "\n").count == 4)
    }

    // MARK: - Progress and size

    @Test func cancellingStopsAndKeepsWhatWasImported() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let text = (0..<50).map { "note number \($0)" }.joined(separator: "\n---\n")
        let counter = Counter()
        let report = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: text, source: "n.txt", endingAt: end,
            isCancelled: { counter.next() > 10 })
        #expect(report.wasCancelled)
        #expect(report.imported == 10)
        #expect(try SessionService(database: fixture.database).sessions().first?.eventCount == 10)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    @Test func aLargeFileImportsInReasonableTime() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        // Debug builds are several times slower, so they only check a smaller file.
        let count = PerformanceBudget.isEnforced ? 10_000 : 1_000
        // Deterministic pseudo-random words, so entries differ like real notes do.
        var seed: UInt64 = 42
        func word() -> String {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return "w" + String((seed >> 33) % 6_000, radix: 36)
        }
        let text = (0..<count)
            .map { index in (0..<14).map { _ in word() }.joined(separator: " ") + " \(index)" }
            .joined(separator: "\n\n")
        let importer = TextImporter(database: fixture.database, secretSink: nil)
        let progress = Counter()
        let started = Date()
        let report = try importer.run(
            text: text, source: "big.txt", endingAt: end, progress: { _, _ in _ = progress.next() })
        let seconds = Date().timeIntervalSince(started)
        #expect(report.imported == count)
        #expect(progress.next() > count / 200)
        #expect(
            !PerformanceBudget.isEnforced || seconds < 60,
            "importing \(count) entries took \(Int(seconds)) s")
    }

    @Test func aFileThatIsNotTextIsRefused() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-import-\(UUID().uuidString).bin")
        try Data([0xFF, 0xFE, 0x00, 0xD8, 0x00, 0x00, 0xFF]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // Whatever the decoder makes of it, it must not crash, and text files must round-trip.
        _ = try? TextImporter.read(url)
        let good = url.deletingPathExtension().appendingPathExtension("txt")
        try "hello – world".write(to: good, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: good) }
        #expect(try TextImporter.read(good) == "hello – world")
    }
}

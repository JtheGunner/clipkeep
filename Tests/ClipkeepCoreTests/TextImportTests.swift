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
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.eventCount == 1 })
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

    // MARK: - Time distribution

    private func calendarDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0
    )
        -> Date
    {
        Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func heading(_ line: String) -> Date? {
        DateHeading.parse(Substring(line))?.date
    }

    @Test func dateHeadingsAreRecognisedInCommonFormats() {
        let march5 = calendarDate(2024, 3, 5)
        #expect(heading("2024-03-05") == march5)
        #expect(heading("## 2024-03-05") == march5)
        #expect(heading("**5.3.2024**") == march5)
        #expect(heading("05.03.2024:") == march5)
        #expect(heading("Dienstag, 5. März 2024") == march5)
        #expect(heading("5 March 2024") == march5)
        #expect(heading("March 5, 2024") == march5)
        #expect(heading("Tue, March 5th 2024") == march5)
        #expect(heading("2024-03-05 14:30") == calendarDate(2024, 3, 5, 14, 30))
        #expect(heading("5.3.2024, 08:15 Uhr") == calendarDate(2024, 3, 5, 8, 15))
    }

    @Test func linesThatOnlyContainADateAreHeadingsAndOthersAreNot() {
        #expect(heading("03/05/2024") == nil)
        #expect(heading("2024-13-45") == nil)
        #expect(heading("30.2.2024") == nil)
        #expect(heading("1850-01-01") == nil)
        #expect(heading("2024-03-05 25:00") == nil)
        #expect(heading("Meeting on 2024-03-05") == nil)
        #expect(heading("2024-03-05 notes") == nil)
        #expect(heading("Foo 5 Bar 2024") == nil)
        #expect(heading("version 1.2.2024 released") == nil)
    }

    @Test func entriesUnderAHeadingGetThatDayInFileOrder() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let text = """
            2024-03-05
            first note

            second note

            2024-03-06
            third note
            """
        let report = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: text, source: "n.txt", endingAt: end)
        #expect(report.imported == 3)
        #expect(report.headingCount == 2)
        let rows = try fixture.database.read { connection in
            try connection.query(
                """
                SELECT c.text, e.copied_at FROM copy_events e
                JOIN contents c ON c.id = e.content_id ORDER BY e.copied_at
                """
            ) { ($0.text(0), $0.double(1)) }
        }
        #expect(rows.map(\.0) == ["first note", "second note", "third note"])
        let march5 = calendarDate(2024, 3, 5).timeIntervalSince1970
        #expect(rows[0].1 == march5)
        #expect(rows[1].1 == march5 + 1)
        #expect(rows[2].1 == calendarDate(2024, 3, 6).timeIntervalSince1970)
        let sessions = try SessionService(database: fixture.database).sessions()
        #expect(sessions.map(\.eventCount).sorted() == [1, 2])
    }

    @Test func headingsInDescendingOrderStillDateTheirEntries() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let text = "2024-03-06\nnewer note\n---\n2024-03-05\nolder note"
        _ = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: text, source: "n.txt", endingAt: end)
        let texts = try fixture.database.read {
            try $0.query(
                "SELECT c.text FROM copy_events e JOIN contents c ON c.id = e.content_id ORDER BY e.copied_at"
            ) { $0.text(0) }
        }
        #expect(texts == ["older note", "newer note"])
    }

    @Test func entriesBeforeTheFirstHeadingTakeItsDate() {
        let split = TextSplitter.splitDated("loose note\n---\n2024-03-05\nnote one")
        #expect(split.headingCount == 1)
        #expect(split.entries.map(\.text) == ["loose note", "note one"])
        #expect(Set(split.entries.compactMap { $0.heading?.date }) == [calendarDate(2024, 3, 5)])
    }

    @Test func aHeadingInsideAnArmoredBlockStaysText() {
        let text =
            "2024-03-05\n-----BEGIN PRIVATE KEY-----\nabc\n2024-03-06\n-----END PRIVATE KEY-----"
        let split = TextSplitter.splitDated(text, mode: .blankLines)
        #expect(split.headingCount == 1)
        #expect(split.entries.count == 1)
        #expect(split.entries[0].text.contains("2024-03-06"))
    }

    @Test func aLabelStaysWithItsValueAcrossAHeading() {
        let split = TextSplitter.splitDated("2024-03-05\nPasswort:\n2024-03-06\nhunter2 value")
        #expect(split.entries.count == 1)
        #expect(split.entries[0].text.contains("Passwort:"))
        #expect(split.entries[0].text.contains("hunter2"))
    }

    @Test func aDocumentWithoutHeadingsGivesNoHeadings() {
        let split = TextSplitter.splitDated("one\n---\ntwo")
        #expect(split.headingCount == 0)
        #expect(split.entries.allSatisfy { $0.heading == nil })
    }

    @Test func withoutHeadingsEveryBlockIsASessionOfItsOwn() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let report = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: "alpha note\n---\nbeta note\n---\ngamma note", source: "n.txt", endingAt: end)
        #expect(report.headingCount == 0)
        let sessions = try SessionService(database: fixture.database).sessions()
        #expect(sessions.count == 3)
        let times = try fixture.database.read {
            try $0.query("SELECT copied_at FROM copy_events ORDER BY copied_at") { $0.double(0) }
        }
        #expect(times.last == end.timeIntervalSince1970)
        #expect(times[1] - times[0] == TextImporter.blockSpacing)
    }

    @Test func noEntryIsDatedAfterTheFileDate() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let early = Date(timeIntervalSince1970: calendarDate(2024, 3, 5).timeIntervalSince1970 + 60)
        _ = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: "2024-03-05\nfirst note\n---\n2030-01-01\nfuture note", source: "n.txt",
            endingAt: early)
        let latest = try fixture.database.read {
            try $0.query("SELECT max(copied_at) FROM copy_events") { $0.double(0) }.first
        }
        #expect(latest == early.timeIntervalSince1970)
    }

    @Test func datedEntriesStayBeforeLiveHistory() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let live = calendarDate(2024, 3, 5, 9, 30)
        _ = try ContentStore(database: fixture.database).record(text: "live copy", copiedAt: live)
        _ = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: "2024-03-05\nold note", source: "n.txt", endingAt: end)
        let latest = try fixture.database.read {
            try $0.query(
                "SELECT max(e.copied_at) FROM copy_events e JOIN contents c ON c.id = e.content_id WHERE c.text = 'old note'"
            ) { $0.double(0) }.first
        }
        #expect(try #require(latest) <= live.timeIntervalSince1970 - 3_600)
    }

    @Test func headingsDoNotBecomeEntriesAndThePreviewCountsThem() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let preview = try TextImporter(database: fixture.database, secretSink: nil)
            .preview(text: "2024-03-05\nfirst note\n\nsecond note\n\n2024-03-06\nthird note")
        #expect(preview.headingCount == 2)
        #expect(preview.entryCount == 3)
        #expect(!preview.samples.joined().contains("2024-03"))
    }

    @Test func importingADatedFileAgainAddsNothing() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let importer = TextImporter(database: fixture.database, secretSink: nil)
        let text = "2024-03-05\nfirst note\n\nsecond note"
        _ = try importer.run(text: text, source: "n.txt", endingAt: end)
        let again = try importer.run(text: text, source: "n.txt", endingAt: end)
        #expect(again.imported == 0)
        #expect(again.duplicates == 2)
    }

    @Test func aSecretUnderAHeadingNeverReachesTheDatabase() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let sink = RecordingSink()
        let report = try TextImporter(database: fixture.database, secretSink: sink).run(
            text: "2024-03-05\nplain note\n---\nexport TOKEN=\(token)", source: "n.txt",
            endingAt: end)
        #expect(report.secrets == 1)
        #expect(sink.secrets.count == 1)
        try expectNoTrace(of: token, in: fixture.database)
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

    @Test func thePreviewWarnsWhenASecretTakesALargeBlockWithIt() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let big = String(repeating: "note about the project plan\n", count: 40)
        let text = "short note here\n---\n\(big)export TOKEN=\(token)\n---\nanother short note"
        let preview = try TextImporter(database: fixture.database, secretSink: nil)
            .preview(text: text)
        #expect(preview.secretCount == 1)
        #expect(preview.secretShare > ImportPreview.largeSecretShare)
        #expect(preview.warnsAboutSecretBlocks)
    }

    @Test func thePreviewDoesNotWarnForASmallSecretEntry() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let notes = (1...20).map { "a perfectly normal note number \($0)" }.joined(
            separator: "\n---\n")
        let text = notes + "\n---\nexport TOKEN=\(token)"
        let preview = try TextImporter(database: fixture.database, secretSink: nil)
            .preview(text: text)
        #expect(preview.secretCount == 1)
        #expect(preview.secretShare < ImportPreview.largeSecretShare)
        #expect(!preview.warnsAboutSecretBlocks)
    }

    @Test func thePreviewDoesNotWarnWithoutSecrets() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let preview = try TextImporter(database: fixture.database, secretSink: nil)
            .preview(text: "first note here\n---\nsecond note here")
        #expect(preview.secretShare == 0)
        #expect(!preview.warnsAboutSecretBlocks)
    }

    @Test func parkedSecretsDoNotCountTowardsTheWarning() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let sink = ParkedSink()
        let preview = try TextImporter(database: fixture.database, secretSink: sink)
            .preview(text: "export TOKEN=\(token)\n---\nsome other note")
        #expect(preview.secretCount == 0)
        #expect(!preview.warnsAboutSecretBlocks)
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
        #expect(try SessionService(database: fixture.database).sessions().count == 10)
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
        let count = PerformanceBudget.isEnforced ? 3_000 : 500
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
            !PerformanceBudget.isEnforced || seconds < 30,
            "importing \(count) entries took \(Int(seconds)) s")
    }

    @Test func commonTextEncodingsAreRead() throws {
        #expect(try TextImporter.decode(Data("grüsse – ok".utf8)) == "grüsse – ok")
        #expect(try TextImporter.decode("grüsse".data(using: .utf16) ?? Data()) == "grüsse")
        // Windows-1252: ü is 0xFC, the euro sign 0x80.
        #expect(try TextImporter.decode(Data([0x67, 0x72, 0xFC, 0x80])) == "grü€")
    }

    @Test func binaryDataIsRefused() {
        #expect(throws: CocoaError.self) {
            try TextImporter.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x1A]))
        }
    }

    @Test func aDirectoryIsRefused() {
        #expect(throws: CocoaError.self) {
            try TextImporter.read(FileManager.default.temporaryDirectory)
        }
    }

    @Test func aSymlinkToATextFileIsFollowed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("real.txt")
        try "linked note".write(to: file, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try TextImporter.read(link) == "linked note")
    }

    @Test func aTextFileOnDiskRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-import-\(UUID().uuidString).txt")
        try "hello – world".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TextImporter.read(url) == "hello – world")
    }

    // MARK: - Secrets across the split

    private var pem: String {
        let body = (0..<6).map { _ in String(repeating: "Zm9vYmFyYmF6", count: 5) }
        // A base64 line may start with a slash; the detector alone would miss it.
        let lines = ["/" + body[0]] + body.dropFirst()
        return
            (["-----BEGIN " + "PRIVATE KEY-----"] + lines + ["", "-----END " + "PRIVATE KEY-----"])
            .joined(separator: "\n")
    }

    @Test(arguments: [SplitMode.automatic, .everyLine, .blankLines, .separatorLines])
    func anArmoredBlockStaysOneEntryInEveryMode(mode: SplitMode) {
        let text = "before\n---\n\n\(pem)\n\nafter"
        let entries = TextSplitter.split(text, mode: mode)
        let block = entries.filter { $0.contains("BEGIN") }
        #expect(block.count == 1)
        #expect(block[0].contains("END PRIVATE KEY"))
        #expect(block[0].contains("Zm9vYmFy"))
        #expect(!entries.filter { !$0.contains("BEGIN") }.contains { $0.contains("Zm9v") })
    }

    @Test func aKeyBlockNeverReachesTheDatabaseInPieces() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let sink = RecordingSink()
        for mode in [SplitMode.everyLine, .blankLines] {
            _ = try TextImporter(database: fixture.database, secretSink: sink).run(
                text: "note one\n\n\(pem)\n\nnote two", mode: mode, source: "n.txt",
                endingAt: end)
        }
        #expect(sink.secrets.count >= 1)
        try expectNoTrace(of: "Zm9vYmFyYmF6", in: fixture.database)
    }

    @Test func aLabelStaysWithItsValue() {
        #expect(TextSplitter.split("Passwort:\n\nhunter2 value", mode: .blankLines).count == 1)
        #expect(TextSplitter.split("API key:\nabc", mode: .everyLine) == ["API key:\nabc"])
        #expect(TextSplitter.split("Meeting at noon:\n\nbring notes", mode: .blankLines).count == 2)
    }

    // MARK: - Repeats and placement

    private final class ParkedSink: SecretSink, @unchecked Sendable {
        var handled = 0
        func handle(secret text: String, context: CopyContext, copiedAt: Date) { handled += 1 }
        func isParked(_ text: String) -> Bool { true }
    }

    private final class FailingSink: SecretSink, @unchecked Sendable {
        func handle(secret text: String, context: CopyContext, copiedAt: Date) {}
        func park(secret text: String, context: CopyContext, copiedAt: Date) -> Bool { false }
    }

    @Test func aSecretThatCannotBeParkedIsNotCountedAsSecured() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let importer = TextImporter(database: fixture.database, secretSink: FailingSink())
        let report = try importer.run(
            text: "export TOKEN=\(token)\n---\nplain note", source: "n.txt", endingAt: end)
        #expect(report.secrets == 0)
        #expect(report.secretsFailed == 1)
        #expect(report.imported == 1)
    }

    @Test func aSecretThatIsAlreadyParkedIsNotParkedAgain() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let sink = ParkedSink()
        let importer = TextImporter(database: fixture.database, secretSink: sink)
        let report = try importer.run(
            text: "export TOKEN=\(token)\n---\nplain note", source: "n.txt", endingAt: end)
        #expect(sink.handled == 0)
        #expect(report.secrets == 0)
        #expect(report.duplicates == 1)
        #expect(try importer.preview(text: "export TOKEN=\(token)").alreadyStoredCount == 1)
    }

    @Test func importedEntriesGoBeforeLiveHistoryWithAPause() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let live = end.addingTimeInterval(-600)
        _ = try ContentStore(database: fixture.database).record(text: "live copy", copiedAt: live)
        _ = try TextImporter(database: fixture.database, secretSink: nil).run(
            text: "old one\n---\nold two", source: "n.txt", endingAt: end)
        let sessions = try SessionService(database: fixture.database).sessions()
        #expect(sessions.count == 3)
        let imported = try #require(sessions.last)
        #expect(imported.eventCount == 1)
        #expect(sessions.dropFirst().allSatisfy { $0.endedAt <= live.addingTimeInterval(-3_600) })
    }

    @Test func duplicatesInsideTheFileCountAsAlreadyThereInThePreview() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let preview = try TextImporter(database: fixture.database, secretSink: nil)
            .preview(text: "same note\n---\nsame note\n---\nother note")
        #expect(preview.alreadyStoredCount == 1)
    }

    @Test func aSecretInASkippedEntryIsNotShownInThePreview() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let long = "export TOKEN=\(token) " + String(repeating: "x", count: 1_100_000)
        let preview = try TextImporter(database: fixture.database, secretSink: nil)
            .preview(text: long)
        #expect(preview.tooLongCount == 1)
        #expect(!preview.samples.joined().contains(token))
    }
}

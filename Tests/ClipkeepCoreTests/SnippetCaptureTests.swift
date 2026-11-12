import Foundation
import Testing

@testable import ClipkeepCore

private final class ErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var errors: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Suite struct SnippetCaptureTests {
    private static let sql = "SELECT id, name FROM users WHERE active = 1 ORDER BY name;"
    private static let secretShell =
        "DB_PASSWORD=hunter2hunter2 ./scripts/test.sh --filter Core"
    private static let plainText = "public.utf8-plain-text"

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let snippets: SnippetStore
        let counter = ErrorCounter()
        let pipeline: CapturePipeline

        init(
            snippetControl: SnippetCaptureControl = SnippetCaptureControl(),
            control: CaptureControl = CaptureControl()
        ) throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            snippets = SnippetStore(database: database)
            let counter = self.counter
            pipeline = CapturePipeline(
                store: ContentStore(database: database), control: control,
                snippets: SnippetCapture(
                    store: snippets, control: snippetControl, onError: { _ in counter.add() }))
        }

        func copy(
            _ text: String, types: Set<String> = [SnippetCaptureTests.plainText],
            app: CopyContext = CopyContext(appBundleID: "com.example.terminal", appName: "Terminal")
        ) throws -> CaptureOutcome {
            try pipeline.process(
                PasteboardSnapshot(changeCount: 1, types: types, text: text), source: app)
        }
    }

    private func expectRecorded(_ outcome: CaptureOutcome) {
        guard case .recorded = outcome else {
            Issue.record("expected recorded, got \(outcome)")
            return
        }
    }

    @Test func codeCopyBecomesASnippetAndAHistoryEntry() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        expectRecorded(try fixture.copy(Self.sql))
        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.count == 1)
        #expect(stored.first?.text == Self.sql)
        #expect(stored.first?.language == .sql)
        #expect(stored.first?.origin == .auto)
        #expect(stored.first?.appName == "Terminal")
    }

    @Test func copyingTheSameCodeAgainBumpsTheSnippet() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.copy(Self.sql)
        _ = try fixture.copy(Self.sql)
        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.count == 1)
        #expect(stored.first?.copyCount == 2)
    }

    @Test func proseIsNotStoredAsASnippetButStaysInTheHistory() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        expectRecorded(try fixture.copy("Let us meet tomorrow at noon to talk about the plan."))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func secretBearingCodeIsStoredAnonymisedAndSkippedInTheHistory() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        #expect(try fixture.copy(Self.secretShell) == .skipped(.secret))
        let stored = try fixture.snippets.list(limit: 10)
        #expect(stored.count == 1)
        #expect(stored.first?.text.contains("<VALUE>") == true)
        #expect(stored.first?.text.contains("hunter2hunter2") == false)
    }

    @Test func nothingIsCapturedWhenPaused() throws {
        let fixture = try Fixture(control: CaptureControl(paused: true))
        defer { fixture.temp.remove() }
        #expect(try fixture.copy(Self.sql) == .skipped(.paused))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func nothingIsCapturedFromABlockedApp() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let blocked = CopyContext(appBundleID: "com.1password.1password", appName: "1Password")
        #expect(try fixture.copy(Self.sql, app: blocked) == .skipped(.blockedApp))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func nothingIsCapturedFromAnAppTheUserIgnores() throws {
        let fixture = try Fixture(
            control: CaptureControl(rules: IgnoreRules(apps: ["com.example.terminal"])))
        defer { fixture.temp.remove() }
        #expect(try fixture.copy(Self.sql) == .skipped(.blockedApp))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test(arguments: [
        ("org.nspasteboard.ConcealedType", SkipReason.concealed),
        (OwnCopyWriter.markerType, SkipReason.ownCopy),
        ("org.nspasteboard.TransientType", SkipReason.transient),
    ])
    func nothingIsCapturedForMarkedCopies(marker: String, reason: SkipReason) throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        #expect(try fixture.copy(Self.sql, types: [Self.plainText, marker]) == .skipped(reason))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func nothingIsCapturedWhenAnIgnoreRuleMatches() throws {
        let fixture = try Fixture(
            control: CaptureControl(rules: IgnoreRules(patterns: ["^SELECT"])))
        defer { fixture.temp.remove() }
        #expect(try fixture.copy(Self.sql) == .skipped(.ignoredByRule))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func nothingIsCapturedWhenSwitchedOff() throws {
        let fixture = try Fixture(snippetControl: SnippetCaptureControl(enabled: false))
        defer { fixture.temp.remove() }
        expectRecorded(try fixture.copy(Self.sql))
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func aDeletedSnippetIsNotCapturedAgain() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.copy(Self.sql)
        let id = try #require(try fixture.snippets.list(limit: 1).first?.id)
        #expect(try fixture.snippets.delete(id: id))
        _ = try fixture.copy(Self.sql)
        #expect(try fixture.snippets.count() == 0)
    }

    @Test func aSnippetStoreFailureDoesNotBlockTheHistory() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fixture.database.write { try $0.execute("DROP TABLE snippets") }
        expectRecorded(try fixture.copy(Self.sql))
        #expect(fixture.counter.errors == 1)
    }

    @Test func controlPersistsAndRejectsCorruptValues() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let settings = SettingsStore(database: try temp.open())

        let first = try SnippetCaptureControl(settings: settings)
        #expect(first.isEnabled)
        try first.setEnabled(false)
        #expect(!first.isEnabled)
        #expect(try SnippetCaptureControl(settings: settings).isEnabled == false)
        try first.setEnabled(true)
        #expect(try SnippetCaptureControl(settings: settings).isEnabled)

        try settings.set("maybe", for: "snippets.captureEnabled")
        #expect(throws: CaptureControlError.corruptSetting("snippets.captureEnabled")) {
            _ = try SnippetCaptureControl(settings: settings)
        }
    }

    @Test func aFailedSaveKeepsTheCurrentState() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let control = try SnippetCaptureControl(settings: SettingsStore(database: database))
        try database.write { try $0.execute("DROP TABLE settings") }
        #expect(throws: (any Error).self) { try control.setEnabled(false) }
        #expect(control.isEnabled)
    }
}

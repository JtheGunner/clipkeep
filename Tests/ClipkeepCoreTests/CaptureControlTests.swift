import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SettingsStoreTests {
    @Test func storesAndReplacesValues() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let store = SettingsStore(database: try temp.open())
        #expect(try store.string("a") == nil)
        try store.set("one", for: "a")
        try store.set("two", for: "a")
        #expect(try store.string("a") == "two")
        #expect(try store.bool("flag") == nil)
        try store.set(true, for: "flag")
        #expect(try store.bool("flag") == true)
        try store.set(false, for: "flag")
        #expect(try store.bool("flag") == false)
    }
}

@Suite struct CaptureControlTests {
    private func control(_ temp: TemporaryDatabase) throws -> CaptureControl {
        try CaptureControl(settings: SettingsStore(database: try temp.open()))
    }

    @Test func stateSurvivesARestart() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let first = try control(temp)
        try first.setPaused(true)
        try first.addIgnoredApp("com.example.notes")
        try first.addPattern("^internal-")

        let second = try control(temp)
        #expect(second.isPaused)
        #expect(second.rules == IgnoreRules(apps: ["com.example.notes"], patterns: ["^internal-"]))
        #expect(second.matchesPattern("internal-42"))
        try second.togglePause()
        #expect(try control(temp).isPaused == false)
    }

    @Test func rulesCanBeRemoved() throws {
        let control = CaptureControl()
        try control.addIgnoredApp("com.example.a")
        try control.addPattern("secret")
        try control.removeIgnoredApp("com.example.a")
        try control.removePattern("secret")
        try control.removePattern("never added")
        #expect(control.rules == IgnoreRules())
        #expect(!control.matchesPattern("secret"))
    }

    @Test func invalidInputIsRejected() throws {
        let control = CaptureControl()
        #expect(throws: CaptureControlError.invalidPattern("(unclosed")) {
            try control.addPattern("(unclosed")
        }
        #expect(throws: CaptureControlError.patternTooLong) {
            try control.addPattern(String(repeating: "a", count: 501))
        }
        #expect(throws: CaptureControlError.invalidBundleID) { try control.addIgnoredApp("  ") }
        #expect(throws: CaptureControlError.invalidBundleID) { try control.addIgnoredApp("a b") }
        for index in 0..<CaptureControl.maximumPatterns { try control.addPattern("p\(index)") }
        #expect(throws: CaptureControlError.tooManyPatterns) { try control.addPattern("extra") }
        try control.addPattern("p0")  // duplicates are ignored, not counted
        #expect(control.rules.patterns.count == CaptureControl.maximumPatterns)
    }

    @Test func catastrophicPatternsCountAsMatchedInsteadOfHanging() {
        let control = CaptureControl(rules: IgnoreRules(patterns: ["(a+)+$"]))
        let text = String(repeating: "a", count: 5_000) + "b"
        let start = Date()
        #expect(control.matchesPattern(text))
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func unreadableSettingsKeepCaptureOff() throws {
        for (key, value) in [
            ("capture.paused", "maybe"), ("capture.ignoredApps", "{not json"),
            ("capture.ignoredPatterns", "[\"(unclosed\"]"),
        ] {
            let temp = try TemporaryDatabase()
            defer { temp.remove() }
            let settings = SettingsStore(database: try temp.open())
            try settings.set(value, for: key)
            #expect(throws: CaptureControlError.corruptSetting(key)) {
                _ = try CaptureControl(settings: settings)
            }
        }
    }

    @Test func storedDuplicatePatternsAreMergedOnLoad() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let settings = SettingsStore(database: try temp.open())
        try settings.set("[\"a+\",\"a+\",\"b\"]", for: "capture.ignoredPatterns")
        let control = try CaptureControl(settings: settings)
        #expect(control.rules.patterns == ["a+", "b"])
        try control.removePattern("a+")
        #expect(!control.matchesPattern("aaa"))
    }

    @Test func slowPatternsAreRejectedWhenAdded() {
        let control = CaptureControl()
        #expect(throws: CaptureControlError.patternTooSlow) {
            try control.addPattern("(\\w+\\s?)*x")
        }
        #expect(control.rules.patterns.isEmpty)
    }

    @Test func pausingStaysInEffectWhenSavingFails() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let control = try CaptureControl(settings: SettingsStore(database: database))
        try database.write { try $0.execute("DROP TABLE settings") }
        #expect(throws: (any Error).self) { try control.setPaused(true) }
        #expect(control.isPaused)
        // Resuming is saved first, so a failed save keeps capture paused.
        #expect(throws: (any Error).self) { try control.setPaused(false) }
        #expect(control.isPaused)
    }

    @Test func concurrentEditsKeepRulesAndMatchersInSync() throws {
        let control = CaptureControl()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            try? control.addPattern("rule\(index)x")
        }
        #expect(control.rules.patterns.count == 20)
        for index in 0..<20 { #expect(control.matchesPattern("..rule\(index)x..")) }
    }

    @Test func scanLimitCountsUTF16UnitsAndKeepsCharactersWhole() {
        let control = CaptureControl(rules: IgnoreRules(patterns: ["needle"]))
        let emoji = String(repeating: "😀", count: CaptureControl.maximumScannedCharacters)
        #expect(!control.matchesPattern(emoji + "needle"))
        #expect(control.matchesPattern("😀😀 needle"))
    }

    @Test func patternsOnlyLookAtTheStartOfHugeContent() {
        let control = CaptureControl(rules: IgnoreRules(patterns: ["needle"]))
        let text = String(repeating: "x", count: CaptureControl.maximumScannedCharacters) + "needle"
        #expect(!control.matchesPattern(text))
        #expect(control.matchesPattern("a needle here"))
    }
}

@Suite struct PauseAndIgnoreCaptureTests {
    private let editor = CopyContext(appBundleID: "com.example.editor", appName: "Editor")

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let control: CaptureControl
        let pipeline: CapturePipeline
        let sink = SinkSpy()

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            control = try CaptureControl(settings: SettingsStore(database: database))
            pipeline = CapturePipeline(
                store: ContentStore(database: database), secretSink: sink, control: control)
        }

        func contentCount() throws -> Int64 {
            try database.read {
                try $0.query("SELECT count(*) FROM contents") { $0.int(0) }.first ?? 0
            }
        }
    }

    private final class SinkSpy: SecretSink, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var received: Int { lock.withLock { count } }
        func handle(secret text: String, context: CopyContext, copiedAt: Date) {
            lock.withLock { count += 1 }
        }
    }

    private func snapshot(_ text: String, _ count: Int = 1) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: count, text: text)
    }

    @Test func nothingIsStoredWhilePausedAndCaptureResumesImmediately() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fixture.control.setPaused(true)
        #expect(
            try fixture.pipeline.process(snapshot("while paused"), source: editor)
                == .skipped(.paused))
        #expect(try fixture.contentCount() == 0)
        try fixture.control.setPaused(false)
        guard case .recorded = try fixture.pipeline.process(snapshot("after pause"), source: editor)
        else {
            Issue.record("Expected capture to resume")
            return
        }
        #expect(try fixture.contentCount() == 1)
    }

    @Test func ignoredAppsApplyWithoutARestart() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        guard case .recorded = try fixture.pipeline.process(snapshot("first copy"), source: editor)
        else {
            Issue.record("Expected the first copy to be recorded")
            return
        }
        try fixture.control.addIgnoredApp("com.example.editor")
        #expect(
            try fixture.pipeline.process(snapshot("second copy", 2), source: editor)
                == .skipped(.blockedApp))
        try fixture.control.removeIgnoredApp("com.example.editor")
        guard
            case .recorded = try fixture.pipeline.process(snapshot("third copy", 3), source: editor)
        else {
            Issue.record("Expected capture to resume for the app")
            return
        }
    }

    @Test func contentRulesApplyImmediatelyAndNeverReachTheSecretSink() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fixture.control.addPattern("^internal-")
        let key = "ghp_" + String(repeating: "aB3dE6gH9k", count: 3) + "xyz012"
        #expect(
            try fixture.pipeline.process(snapshot("internal-\(key)"), source: editor)
                == .skipped(.ignoredByRule))
        #expect(fixture.sink.received == 0)
        #expect(try fixture.contentCount() == 0)
        guard
            case .recorded = try fixture.pipeline.process(
                snapshot("public note", 2), source: editor)
        else {
            Issue.record("Expected a non-matching copy to be recorded")
            return
        }
    }

    @Test func aCopyDuringAPauseThatEndedBeforeTheNextPollIsDropped() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let board = PausedBoard()
        let poller = ClipboardPoller(
            pasteboard: board, source: PausedSource(), pipeline: fixture.pipeline)
        try fixture.control.setPaused(true)
        board.set(PasteboardSnapshot(changeCount: 2, text: "copied in a short pause"))
        try fixture.control.setPaused(false)
        #expect(poller.poll() == .skipped(.paused))
        #expect(try fixture.contentCount() == 0)
        // A pause and resume without any copy does not swallow the next copy.
        try fixture.control.setPaused(true)
        try fixture.control.setPaused(false)
        #expect(poller.poll() == nil)
        board.set(PasteboardSnapshot(changeCount: 3, text: "copied after resuming"))
        guard case .recorded = poller.poll() else {
            Issue.record("Expected the copy after resuming to be recorded")
            return
        }
    }

    @Test func aPauseDuringDetailLookupStopsTheCopy() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let control = CaptureControl()
        let pipeline = CapturePipeline(
            store: ContentStore(database: database),
            contextDetails: PausingDetails(control: control), control: control)
        let outcome = try pipeline.process(snapshot("sensitive words"), source: editor)
        #expect(outcome == .skipped(.paused))
        let count = try database.read {
            try $0.query("SELECT count(*) FROM contents") { $0.int(0) }.first
        }
        #expect(count == 0)
    }

    @Test func aPauseThatEndsDuringDetailLookupStillStopsTheCopy() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let control = CaptureControl()
        let pipeline = CapturePipeline(
            store: ContentStore(database: database),
            contextDetails: PauseResumeDetails(control: control), control: control)
        #expect(
            try pipeline.process(snapshot("sensitive words"), source: editor) == .skipped(.paused))
        #expect(!control.isPaused)
    }

    private struct PauseResumeDetails: ContextDetailProviding {
        let control: CaptureControl
        func details(for source: CopyContext) -> CopyContext {
            try? control.setPaused(true)
            try? control.setPaused(false)
            return source
        }
    }

    @Test func anIgnoredAppAnywhereInTheSourceWindowBlocksTheCopy() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        try fixture.control.addIgnoredApp("com.example.notes")
        let outcome = try fixture.pipeline.process(
            snapshot("window crossing"),
            sources: [editor, CopyContext(appBundleID: "com.example.notes")])
        #expect(outcome == .skipped(.blockedApp))
    }

    private struct PausingDetails: ContextDetailProviding {
        let control: CaptureControl
        func details(for source: CopyContext) -> CopyContext {
            try? control.setPaused(true)
            return source
        }
    }

    @Test func pollerDoesNotReadOrReplayCopiesMadeWhilePaused() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let board = PausedBoard()
        let poller = ClipboardPoller(
            pasteboard: board, source: PausedSource(), pipeline: fixture.pipeline)
        try fixture.control.setPaused(true)
        board.set(PasteboardSnapshot(changeCount: 2, text: "copied during pause"))
        #expect(poller.poll() == .skipped(.paused))
        #expect(board.snapshotCalls == 0)
        try fixture.control.setPaused(false)
        #expect(poller.poll() == nil)
        #expect(try fixture.contentCount() == 0)
    }

    private final class PausedBoard: PasteboardReading, @unchecked Sendable {
        private let lock = NSLock()
        private var current = PasteboardSnapshot(changeCount: 1)
        private var calls = 0
        var changeCount: Int { lock.withLock { current.changeCount } }
        var snapshotCalls: Int { lock.withLock { calls } }
        func set(_ value: PasteboardSnapshot) { lock.withLock { current = value } }
        func snapshot() -> PasteboardSnapshot? {
            lock.withLock {
                calls += 1
                return current
            }
        }
    }

    private struct PausedSource: SourceAppProviding {
        func sources(from start: Date, to end: Date) -> [CopyContext] {
            [CopyContext(appBundleID: "com.example.editor")]
        }
    }
}

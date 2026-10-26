import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct ContextSanitizerTests {
    @Test func titlesBecomeSingleTrimmedShortLines() {
        #expect(
            ContextSanitizer.title("  Pull request #4 \n  clipkeep ") == "Pull request #4 clipkeep")
        #expect(ContextSanitizer.title("   \n ") == nil)
        #expect(ContextSanitizer.title(nil) == nil)
        let long = String(repeating: "a", count: 500)
        #expect(ContextSanitizer.title(long)?.count == ContextSanitizer.maximumTitleLength)
    }

    @Test func urlsKeepOnlySchemeHostAndPath() {
        #expect(
            ContextSanitizer.url("https://user:pw@GitHub.com:8443/acme/api/issues/1?token=abc#top")
                == "https://github.com:8443/acme/api/issues/1")
        #expect(ContextSanitizer.url(" http://example.com/a?b=c ") == "http://example.com/a")
    }

    @Test(arguments: [
        "about:blank", "file:///tmp/a.txt", "javascript:alert(1)", "not a url", "", "https://",
    ])
    func nonWebAddressesAreDropped(raw: String) {
        #expect(ContextSanitizer.url(raw) == nil)
    }

    @Test func overlongAddressesAreDropped() {
        let path = String(repeating: "a", count: 600)
        #expect(ContextSanitizer.url("https://example.com/\(path)") == nil)
        #expect(ContextSanitizer.url(nil) == nil)
    }
}

@Suite struct BrowserCatalogTests {
    @Test func knownBrowsersHaveScripts() {
        for bundleID in BrowserCatalog.bundleIDs {
            let script = BrowserCatalog.script(forBundleID: bundleID)
            #expect(script?.contains(bundleID) == true)
            #expect(script?.contains("with timeout") == true)
        }
        #expect(BrowserCatalog.script(forBundleID: "com.example.editor") == nil)
        #expect(BrowserCatalog.isBrowser("com.google.Chrome"))
        #expect(!BrowserCatalog.isBrowser("com.example.editor"))
    }

    @Test func chromiumScriptsSkipPrivateWindowsAndSafariUsesDocuments() {
        let chrome = BrowserCatalog.script(forBundleID: "com.google.Chrome") ?? ""
        #expect(chrome.contains("is not \"normal\""))
        #expect(chrome.contains("on error"))
        #expect(chrome.contains(BrowserCatalog.privateMarker))
        #expect(chrome.contains("active tab"))
        let safari = BrowserCatalog.script(forBundleID: "com.apple.Safari") ?? ""
        #expect(safari.contains("front document"))
        #expect(!safari.contains("incognito"))
    }
}

@Suite struct ContextReaderTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var titleCalls = 0
        private var addressCalls = 0
        var titles: Int { lock.withLock { titleCalls } }
        var addresses: Int { lock.withLock { addressCalls } }
        func title() { lock.withLock { titleCalls += 1 } }
        func address() { lock.withLock { addressCalls += 1 } }
    }

    private func reader(
        front: ContextEnvironment.FrontApp?, title: String?, address: String?,
        calls: Calls = Calls(), readsSafari: Bool = true
    ) -> ContextReader {
        ContextReader(
            environment: ContextEnvironment(
                frontmostApp: { front },
                windowTitle: { _ in
                    calls.title()
                    return title
                },
                browserAddress: { _, _ in
                    calls.address()
                    return address
                }),
            readsSafari: { readsSafari })
    }

    @Test func addsTitleToTheFrontmostSourceApp() {
        let reader = reader(
            front: .init(bundleID: "com.example.editor", processID: 7),
            title: "main.swift — clipkeep",
            address: nil)
        let result = reader.details(
            for: CopyContext(appBundleID: "com.example.editor", appName: "Editor"))
        #expect(result.windowTitle == "main.swift — clipkeep")
        #expect(result.url == nil)
        #expect(result.appName == "Editor")
    }

    @Test func addsTheAddressForBrowsers() {
        let reader = reader(
            front: .init(bundleID: "com.apple.Safari", processID: 9), title: "Docs",
            address: "https://example.com/docs?x=1")
        let result = reader.details(for: CopyContext(appBundleID: "com.apple.Safari"))
        #expect(result.url == "https://example.com/docs")
        #expect(result.windowTitle == "Docs")
    }

    @Test func nothingIsReadWhenAnotherAppIsFrontmostNow() {
        let calls = Calls()
        let reader = reader(
            front: .init(bundleID: "com.apple.Safari", processID: 9), title: "Wrong window",
            address: "https://wrong.example", calls: calls)
        let source = CopyContext(appBundleID: "com.example.editor", appName: "Editor")
        #expect(reader.details(for: source) == source)
        #expect(calls.titles == 0 && calls.addresses == 0)
        #expect(reader.details(for: CopyContext()) == CopyContext())
    }

    @Test func missingPermissionsLeaveFieldsEmpty() {
        let reader = reader(
            front: .init(bundleID: "com.google.Chrome", processID: 3), title: nil, address: nil)
        let source = CopyContext(appBundleID: "com.google.Chrome", appName: "Chrome")
        #expect(reader.details(for: source) == source)
    }

    @Test func nonBrowsersNeverRunScripts() {
        let calls = Calls()
        let reader = reader(
            front: .init(bundleID: "com.example.editor", processID: 1), title: "t",
            address: "https://example.com", calls: calls)
        _ = reader.details(for: CopyContext(appBundleID: "com.example.editor"))
        #expect(calls.addresses == 0)
    }
}

@Suite struct ContextPrivacyTests {
    private func reader(
        bundleID: String, title: String?, address: String?, readsSafari: Bool = true
    ) -> ContextReader {
        ContextReader(
            environment: ContextEnvironment(
                frontmostApp: { .init(bundleID: bundleID, processID: 1) },
                windowTitle: { _ in title }, browserAddress: { _, _ in address }),
            readsSafari: { readsSafari })
    }

    @Test func privateWindowsDropTitleAndAddress() {
        let chrome = reader(
            bundleID: "com.google.Chrome", title: "Diagnosis forum",
            address: BrowserCatalog.privateMarker)
        let source = CopyContext(appBundleID: "com.google.Chrome", appName: "Chrome")
        #expect(chrome.details(for: source) == source)
    }

    @Test(arguments: ["Shop — Private Browsing", "News - InPrivate", "Forum (Incognito)"])
    func titlesThatMarkPrivateWindowsAreDropped(title: String) {
        let firefox = reader(bundleID: "org.mozilla.firefox", title: title, address: nil)
        let source = CopyContext(appBundleID: "org.mozilla.firefox")
        #expect(firefox.details(for: source) == source)
    }

    @Test func safariIsOnlyReadWhenAllowed() {
        let source = CopyContext(appBundleID: "com.apple.Safari")
        let blocked = reader(
            bundleID: "com.apple.Safari", title: "Page", address: "https://example.com/a",
            readsSafari: false)
        #expect(blocked.details(for: source) == source)
        let allowed = reader(
            bundleID: "com.apple.Safari", title: "Page", address: "https://example.com/a")
        #expect(allowed.details(for: source).url == "https://example.com/a")
    }

    @Test func secretsInTitlesAndAddressesAreDropped() {
        let key = "ghp_" + String(repeating: "aB3dE6gH9k", count: 3) + "xyz012"
        let terminal = reader(
            bundleID: "com.apple.Terminal", title: "curl -H token \(key)", address: nil)
        let result = terminal.details(
            for: CopyContext(appBundleID: "com.apple.Terminal", appName: "Terminal"))
        #expect(result.windowTitle == nil)
        #expect(result.appName == "Terminal")

        let browser = reader(
            bundleID: "com.google.Chrome", title: "Hook",
            address: "https://hooks.example.com/\(key)")
        let page = browser.details(for: CopyContext(appBundleID: "com.google.Chrome"))
        #expect(page.url == nil)
        #expect(page.windowTitle == "Hook")
    }

    @Test func controlAndBidiCharactersAreStrippedFromTitles() {
        #expect(ContextSanitizer.title("a\u{202E}b\u{200B}c\u{7}d") == "abcd")
        #expect(ContextSanitizer.title("\u{200B}") == nil)
    }

    @Test func urlEdgeCases() {
        #expect(ContextSanitizer.url("http://[::1]:8080/a?x") == "http://[::1]:8080/a")
        #expect(ContextSanitizer.url("https://token@github.com/a") == "https://github.com/a")
        #expect(ContextSanitizer.url("HTTPS://Example.COM/a b") == "https://example.com/a%20b")
        #expect(ContextSanitizer.url("https://example.com?") == "https://example.com")
        #expect(ContextSanitizer.url("https://example.com#frag") == "https://example.com")
    }
}

@Suite struct ContextCaptureTests {
    private struct Spy: ContextDetailProviding {
        let counter: Counter
        func details(for source: CopyContext) -> CopyContext {
            counter.increment()
            var result = source
            result.windowTitle = "Window"
            result.url = "https://example.com/page"
            return result
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    @Test func detailsAreStoredPerEventAndSkippedCopiesAreNotQueried() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let counter = Counter()
        let pipeline = CapturePipeline(
            store: ContentStore(database: database), contextDetails: Spy(counter: counter))
        let editor = CopyContext(appBundleID: "com.example.editor", appName: "Editor")

        _ = try pipeline.process(
            PasteboardSnapshot(
                changeCount: 1, types: ["org.nspasteboard.ConcealedType"], text: "hidden words"),
            source: editor)
        _ = try pipeline.process(
            PasteboardSnapshot(changeCount: 2, text: "x"), source: editor)
        #expect(counter.count == 0)

        _ = try pipeline.process(
            PasteboardSnapshot(changeCount: 3, text: "visible words"), source: editor)
        #expect(counter.count == 1)
        let row = try database.read {
            try $0.query("SELECT app_name, window_title, url FROM copy_events") {
                [$0.text(0), $0.text(1), $0.text(2)]
            }.first
        }
        #expect(row == ["Editor", "Window", "https://example.com/page"])
    }

    @Test func withoutDetailsCaptureStoresEmptyFields() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let pipeline = CapturePipeline(store: ContentStore(database: database))
        _ = try pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: "plain copy"),
            source: CopyContext(appBundleID: "com.example.editor"))
        let nulls = try database.read {
            try $0.query("SELECT window_title IS NULL, url IS NULL FROM copy_events") {
                [$0.int(0), $0.int(1)]
            }.first
        }
        #expect(nulls == [1, 1])
    }

    @Test func detailsAreSkippedAfterAnAppSwitchInThePollWindow() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let counter = Counter()
        let pipeline = CapturePipeline(
            store: ContentStore(database: database), contextDetails: Spy(counter: counter))
        let sources = [
            CopyContext(appBundleID: "com.example.editor"),
            CopyContext(appBundleID: "com.example.other"),
        ]
        _ = try pipeline.process(
            PasteboardSnapshot(changeCount: 1, text: "switched quickly"), sources: sources)
        #expect(counter.count == 0)
    }
}

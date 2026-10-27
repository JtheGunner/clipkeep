import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct MarkdownExportTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private var zurich: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .gmt
        return calendar
    }

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database
        let store: ContentStore

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
            store = ContentStore(database: database)
        }
    }

    private func exporter(_ fixture: Fixture) -> MarkdownExporter {
        MarkdownExporter(database: fixture.database, calendar: zurich)
    }

    @Test func aSessionExportsTimeSourceAndContentInOrder() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(
            text: "first copied text", copiedAt: base,
            context: CopyContext(
                appName: "Safari", windowTitle: "Docs page", url: "https://example.com/a"))
        _ = try fixture.store.record(
            text: "second copied text", copiedAt: base.addingTimeInterval(120),
            context: CopyContext(appName: "Xcode"))
        let session = try #require(try SessionService(database: fixture.database).sessions().first)
        let document = try #require(try exporter(fixture).export(.session(session.id)))
        #expect(document.fileName == "clipkeep-session-2027-01-15-0900.md")
        #expect(document.entryCount == 2)
        #expect(document.text.hasPrefix("# Session 15.01.2027 09:00\n"))
        #expect(document.text.contains("### 09:00 · Safari · Text"))
        #expect(document.text.contains("> Docs page · https://example.com/a"))
        #expect(document.text.contains("```text\nfirst copied text\n```"))
        let first = try #require(document.text.range(of: "first copied text"))
        let second = try #require(document.text.range(of: "second copied text"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func aDayCoversAllItsSessionsAndNothingElse() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "morning note", copiedAt: base)
        _ = try fixture.store.record(
            text: "afternoon note", copiedAt: base.addingTimeInterval(4 * 3_600))
        _ = try fixture.store.record(
            text: "next day note", copiedAt: base.addingTimeInterval(86_400))
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.fileName == "clipkeep-2027-01-15.md")
        #expect(document.entryCount == 2)
        #expect(document.text.contains("morning note"))
        #expect(document.text.contains("afternoon note"))
        #expect(!document.text.contains("next day note"))
        #expect(try exporter(fixture).export(.day(base.addingTimeInterval(10 * 86_400))) == nil)
    }

    @Test func aTopicExportsUnderASlugOfItsLabel() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(
            text: "https://github.com/acme/api/issues/1 swift actor", copiedAt: base)
        try TopicService(database: fixture.database).cluster(
            now: base.addingTimeInterval(30 * 86_400))
        let topic = try #require(try TopicService(database: fixture.database).topics().first)
        let document = try #require(try exporter(fixture).export(.topic(topic.id)))
        #expect(document.fileName == "clipkeep-thema-github-com-acme-api.md")
        #expect(document.text.hasPrefix("# Thema: \(topic.label)"))
        #expect(try exporter(fixture).export(.topic(9_999)) == nil)
    }

    @Test(arguments: [
        ("Swift Actors & Isolation", "swift-actors-isolation"), ("Über Größe", "uber-grosse"),
        ("  --  ", "thema"), ("日本語", "thema"),
    ])
    func slugsAreKebabCase(label: String, expected: String) {
        #expect(MarkdownExporter.slug(label) == expected)
    }

    @Test func aLongSlugIsCutWithoutATrailingHyphen() {
        let slug = MarkdownExporter.slug(String(repeating: "word ", count: 30))
        #expect(slug.count <= 40)
        #expect(!slug.hasSuffix("-"))
    }

    // MARK: - Secrets

    @Test func aParkedSecretNeverReachesTheExport() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let label = "OpenAI API-Key · github.com → gesichert"
        _ = try fixture.store.record(
            text: label, copiedAt: base, context: CopyContext(windowTitle: "Key page"),
            kind: .secret)
        _ = try fixture.store.record(text: "plain note", copiedAt: base.addingTimeInterval(60))
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.withheldSecrets == 1)
        #expect(document.text.contains(MarkdownExporter.secretLine))
        #expect(!document.text.contains("OpenAI"))
        #expect(!document.text.contains("Key page"))
        #expect(document.text.contains("plain note"))
    }

    @Test func textTheDetectorStillFlagsIsWithheldToo() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        // Built at runtime so no secret-shaped literal sits in the source.
        let token = "gh" + "p_" + String(repeating: "aB3dE6gH9j", count: 4)
        _ = try fixture.store.record(text: "export TOKEN=\(token)", copiedAt: base)
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.withheldSecrets == 1)
        #expect(!document.text.contains(token))
    }

    @Test func deletedItemsAreNotExported() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let kept = try fixture.store.record(text: "keep me", copiedAt: base)
        let dropped = try fixture.store.record(
            text: "drop me", copiedAt: base.addingTimeInterval(60))
        _ = kept
        try ItemActions(database: fixture.database).delete(contentID: dropped.contentID)
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.text.contains("keep me"))
        #expect(!document.text.contains("drop me"))
    }

    @Test func aTokenInTheWindowTitleWithholdsTheEntry() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let token = "gh" + "p_" + String(repeating: "aB3dE6gH9j", count: 4)
        _ = try fixture.store.record(
            text: "harmless note", copiedAt: base,
            context: CopyContext(windowTitle: "settings \(token)"))
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.withheldSecrets == 1)
        #expect(!document.text.contains(token))
        #expect(!document.text.contains("harmless note"))
    }

    @Test func parkedAndDetectedSecretsAreBothCounted() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let token = "gh" + "p_" + String(repeating: "aB3dE6gH9j", count: 4)
        _ = try fixture.store.record(text: "label only", copiedAt: base, kind: .secret)
        _ = try fixture.store.record(
            text: "TOKEN=\(token)", copiedAt: base.addingTimeInterval(60))
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.withheldSecrets == 2)
        #expect(document.entryCount == 2)
    }

    @Test func aTopicLabelWithANewlineCannotAddHeadings() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "swift actor isolation notes", copiedAt: base)
        let topics = TopicService(database: fixture.database)
        try topics.cluster(now: base.addingTimeInterval(30 * 86_400))
        let topic = try #require(try topics.topics().first)
        try topics.rename(topic: topic.id, to: "first\n## injected")
        let document = try #require(try exporter(fixture).export(.topic(topic.id)))
        #expect(document.text.hasPrefix("# Thema: first ## injected\n"))
        #expect(!document.text.contains("\n## injected"))
    }

    @Test func jsonGetsItsFenceLanguage() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(
            text: "{\"name\": \"value\", \"list\": [1, 2]}", copiedAt: base)
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.text.contains("```json\n"))
    }

    // MARK: - Format

    @Test func contentWithBackticksGetsALongerFence() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(text: "before\n```\ninner\n```\nafter", copiedAt: base)
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.text.contains("````text\nbefore\n```\ninner\n```\nafter\n````"))
    }

    @Test func multiLineWindowTitlesStayOnOneLine() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        _ = try fixture.store.record(
            text: "note", copiedAt: base, context: CopyContext(windowTitle: "line one\n# injected"))
        let document = try #require(try exporter(fixture).export(.day(base)))
        #expect(document.text.contains("> line one # injected"))
        #expect(!document.text.contains("\n# injected"))
    }

    // MARK: - Writing

    @Test func writingNeverReplacesAnExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = MarkdownDocument(
            fileName: "clipkeep-2027-01-15.md", text: "# one", entryCount: 1, withheldSecrets: 0)
        let first = try MarkdownExporter.write(document, to: directory)
        let second = try MarkdownExporter.write(document, to: directory)
        #expect(first.lastPathComponent == "clipkeep-2027-01-15.md")
        #expect(second.lastPathComponent == "clipkeep-2027-01-15-2.md")
        #expect(try String(contentsOf: first, encoding: .utf8) == "# one")
        let permissions =
            try FileManager.default.attributesOfItem(atPath: first.path)[
                .posixPermissions] as? Int
        #expect(permissions == 0o600)
        let bad = MarkdownDocument(fileName: "x.txt", text: "", entryCount: 0, withheldSecrets: 0)
        #expect(throws: CocoaError.self) { try MarkdownExporter.write(bad, to: directory) }
    }
}

import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SimHashTests {
    private let base =
        "The quick brown fox jumps over the lazy dog while the sun sets slowly behind the old "
        + "stone bridge and the river keeps flowing towards the distant sea every single evening"

    @Test func sameTextGivesSameFingerprint() {
        #expect(SimHash.fingerprint(of: base) == SimHash.fingerprint(of: base))
    }

    @Test func caseAndWhitespaceDoNotChangeTheFingerprint() {
        let noisy = "  " + base.uppercased().replacingOccurrences(of: " ", with: "\n  ") + "\n"
        #expect(SimHash.fingerprint(of: base) == SimHash.fingerprint(of: noisy))
    }

    @Test func shortTextHasNoFingerprint() {
        #expect(SimHash.fingerprint(of: "just a few words") == nil)
        #expect(SimHash.fingerprint(of: "") == nil)
    }

    @Test func smallEditStaysCloseAndUnrelatedTextIsFar() throws {
        let edited = base.replacingOccurrences(of: "lazy", with: "sleepy")
        let unrelated =
            "Quarterly revenue grew by twelve percent as subscription renewals offset the decline "
            + "in hardware sales across all European regions during the second half of the fiscal year"
        let original = try #require(SimHash.fingerprint(of: base))
        let near = SimHash.distance(original, try #require(SimHash.fingerprint(of: edited)))
        let far = SimHash.distance(original, try #require(SimHash.fingerprint(of: unrelated)))
        #expect(near <= 12)
        #expect(far > near)
        #expect(far >= 16)
    }

    @Test func hugeTextIsBounded() {
        let huge = String(repeating: "alpha beta gamma delta ", count: 200_000)
        #expect(SimHash.fingerprint(of: huge) != nil)
    }

    @Test func bandsPartitionAllBits() throws {
        let fingerprint: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        let values = FingerprintBands.values(of: fingerprint)
        #expect(values.count == FingerprintBands.count)
        var rebuilt: UInt64 = 0
        for (band, value) in values.enumerated() {
            rebuilt |= UInt64(value) << UInt64(band * 64 / FingerprintBands.count)
        }
        #expect(rebuilt == fingerprint)
    }
}

@Suite struct DuplicateDetectionTests {
    private let article =
        "Release notes for the clipboard tool: the search now supports substring matching, "
        + "the history keeps frequently used snippets longer and the menu bar icon shows paused state. "
        + "Secrets are detected before anything is stored and parked in the keychain until they can "
        + "be moved to the password manager. Sessions group copies that happen close together in time "
        + "and topics collect related snippets from different sessions so that a day of research "
        + "can be reopened later without scrolling through thousands of unrelated entries again."

    private func makeStore(_ configuration: DuplicateConfiguration = .default) throws -> (
        ContentStore, TemporaryDatabase
    ) {
        let temp = try TemporaryDatabase()
        return (ContentStore(database: try temp.open(), duplicates: configuration), temp)
    }

    @Test func exactDuplicateReusesTheContentAndCountsOccurrences() throws {
        let (store, temp) = try makeStore()
        defer { temp.remove() }
        let first = try store.record(text: article)
        let second = try store.record(text: article)
        #expect(first.contentID == second.contentID)
        #expect(try store.occurrenceCount(contentID: first.contentID) == 2)
        #expect(try store.duplicateLinks(of: first.contentID).isEmpty)
    }

    @Test func normalizedDuplicateIsLinkedAndBothTextsSurvive() throws {
        let (store, temp) = try makeStore()
        defer { temp.remove() }
        let first = try store.record(text: "Hello   World")
        let second = try store.record(text: "hello world\n")
        #expect(first.contentID != second.contentID)
        let links = try store.duplicateLinks(of: second.contentID)
        #expect(
            links == [
                DuplicateLink(
                    contentID: second.contentID, relatedID: first.contentID, kind: .normalized,
                    distance: 0)
            ])
        #expect(try store.duplicateLinks(of: first.contentID) == links)
    }

    @Test func graduallyExtendedTextIsLinkedAsNearDuplicate() throws {
        let (store, temp) = try makeStore(DuplicateConfiguration(maximumDistance: 8))
        defer { temp.remove() }
        let first = try store.record(text: article)
        let second = try store.record(text: article + " The exporter now writes markdown files.")
        let links = try store.duplicateLinks(of: second.contentID)
        #expect(links.count == 1)
        #expect(links.first?.kind == .near)
        #expect(links.first?.relatedID == first.contentID)
        #expect(try store.occurrenceCount(contentID: first.contentID) == 1)
        #expect(try store.occurrenceCount(contentID: second.contentID) == 1)
    }

    @Test func unrelatedTextIsNotLinked() throws {
        let (store, temp) = try makeStore()
        defer { temp.remove() }
        _ = try store.record(text: article)
        let other = try store.record(
            text:
                "Quarterly revenue grew by twelve percent as subscription renewals offset the decline "
                + "in hardware sales across all European regions during the second half of the year"
        )
        #expect(try store.duplicateLinks(of: other.contentID).isEmpty)
    }

    @Test func thresholdZeroOnlyLinksIdenticalFingerprints() throws {
        let (store, temp) = try makeStore(DuplicateConfiguration(maximumDistance: 0))
        defer { temp.remove() }
        _ = try store.record(text: article)
        let edited = try store.record(
            text: article.replacingOccurrences(of: "menu bar", with: "status bar"))
        let links = try store.duplicateLinks(of: edited.contentID)
        #expect(links.allSatisfy { $0.distance == 0 })
    }

    @Test func linkCountIsCapped() throws {
        let (store, temp) = try makeStore(
            DuplicateConfiguration(maximumDistance: 8, maximumLinks: 2))
        defer { temp.remove() }
        for suffix in ["one", "two", "three", "four"] {
            _ = try store.record(text: article + " " + suffix)
        }
        let last = try store.record(text: article + " five")
        #expect(
            try store.duplicateLinks(of: last.contentID).filter { $0.contentID == last.contentID }
                .count <= 2)
    }

    @Test func configurationClampsOutOfRangeValues() {
        #expect(DuplicateConfiguration(maximumDistance: 99).maximumDistance == 8)
        #expect(DuplicateConfiguration(maximumDistance: -3).maximumDistance == 0)
        #expect(DuplicateConfiguration(maximumLinks: -1).maximumLinks == 0)
    }

    @Test func deletingContentRemovesItsBandsAndLinks() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let store = ContentStore(
            database: database, duplicates: DuplicateConfiguration(maximumDistance: 8))
        let first = try store.record(text: article)
        let second = try store.record(text: article + " plus one more sentence about exports")
        try database.write {
            try $0.execute("DELETE FROM contents WHERE id = ?", [.int(first.contentID)])
        }
        #expect(try store.duplicateLinks(of: second.contentID).isEmpty)
        let bands = try database.read {
            try $0.query(
                "SELECT count(*) FROM content_bands WHERE content_id = ?", [.int(first.contentID)]
            ) { $0.int(0) }
        }
        #expect(bands == [0])
    }
}

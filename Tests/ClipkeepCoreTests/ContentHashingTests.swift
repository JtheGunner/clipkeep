import Testing

@testable import ClipkeepCore

@Suite struct ContentHashingTests {
    @Test func exactHashIsStableSHA256() {
        #expect(
            ContentHashing.exactHash("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func exactHashDistinguishesCaseAndWhitespace() {
        #expect(ContentHashing.exactHash("a b") != ContentHashing.exactHash("a  b"))
        #expect(ContentHashing.exactHash("A") != ContentHashing.exactHash("a"))
    }

    @Test func normalizedHashIgnoresCaseAndWhitespaceRuns() {
        let variants = ["Hello  World", "  hello world\n", "HELLO\tWORLD"]
        let hashes = Set(variants.map(ContentHashing.normalizedHash))
        #expect(hashes.count == 1)
    }

    @Test func normalizedHashStillSeparatesDifferentWords() {
        #expect(ContentHashing.normalizedHash("a b") != ContentHashing.normalizedHash("ab"))
    }
}

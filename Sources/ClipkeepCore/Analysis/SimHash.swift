import Foundation

/// 64-bit similarity fingerprint over word shingles. Texts that share most of their wording
/// get fingerprints that differ in only a few bits, so near-duplicates can be found by
/// Hamming distance. Texts that share their first `maximumWords` words are indistinguishable. Pure and deterministic: the same text always yields the same value.
public enum SimHash {
    /// Texts with fewer words are too short for a meaningful fingerprint.
    public static let minimumWords = 8
    /// Only the leading words are fingerprinted so a huge paste costs a bounded amount of work.
    public static let maximumWords = 20_000
    static let shingleSize = 3

    /// Returns `nil` when the text has fewer than `minimumWords` words.
    public static func fingerprint(of text: String) -> UInt64? {
        fingerprint(foldedText: SearchText.fold(text))
    }

    /// Same as `fingerprint(of:)` for text that went through `SearchText.fold` already.
    static func fingerprint(foldedText: String) -> UInt64? {
        let words = words(in: foldedText)
        guard words.count >= minimumWords else { return nil }

        var weights = [Int32](repeating: 0, count: 64)
        for start in 0...(words.count - shingleSize) {
            var hash = fnv1a64(words[start])
            for offset in 1..<shingleSize {
                hash = fnv1a64(words[start + offset], seed: hash)
            }
            hash = mix(hash)
            for bit in 0..<64 {
                weights[bit] += (hash >> UInt64(bit)) & 1 == 1 ? 1 : -1
            }
        }
        var result: UInt64 = 0
        for bit in 0..<64 where weights[bit] > 0 {
            result |= 1 << UInt64(bit)
        }
        return result
    }

    public static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Scans lazily and stops after `maximumWords`, so the cost does not grow with huge input.
    private static func words(in folded: String) -> [Substring] {
        var result: [Substring] = []
        var wordStart: String.Index?
        var index = folded.startIndex
        while index < folded.endIndex, result.count < maximumWords {
            let isWordCharacter = folded[index].isLetter || folded[index].isNumber
            if isWordCharacter, wordStart == nil {
                wordStart = index
            } else if !isWordCharacter, let start = wordStart {
                result.append(folded[start..<index])
                wordStart = nil
            }
            index = folded.index(after: index)
        }
        if let start = wordStart, result.count < maximumWords {
            result.append(folded[start..<folded.endIndex])
        }
        return result
    }

    private static func fnv1a64(_ word: Substring, seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
        var hash = seed
        for byte in word.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        // Separator so ("ab","c") and ("a","bc") differ.
        return (hash ^ 0xff) &* 0x0000_0100_0000_01b3
    }

    /// Finalizer (splitmix64) so every output bit depends on every input bit.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

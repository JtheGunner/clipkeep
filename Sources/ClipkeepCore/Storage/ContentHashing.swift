import CryptoKit
import Foundation

public enum ContentHashing {
    /// SHA-256 of the exact text, as lowercase hex.
    public static func exactHash(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// Hash that ignores case, Unicode composition, surrounding whitespace and runs of whitespace.
    public static func normalizedHash(_ text: String) -> String {
        exactHash(normalize(text))
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().split(
            whereSeparator: \.isWhitespace
        ).joined(separator: " ")
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

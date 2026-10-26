import Foundation

public enum SearchText {
    /// Canonical form used for the index and for queries: composed Unicode (so "u" + U+0308 equals
    /// "ü") and lowercased with full Unicode rules, unlike SQLite's ASCII-only `lower()`.
    public static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}

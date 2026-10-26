import Foundation
import NaturalLanguage

/// Turns text into lowercase index terms. Uses the system tokenizer and language detection
/// (local, no network) and drops stop words of the detected language (German or English).
public enum TermTokenizer {
    public static let minimumLength = 3
    public static let maximumLength = 40
    /// Bounds the work for huge texts.
    public static let maximumCharacters = 20_000

    public static func counts(in text: String) -> [String: Int] {
        let sample = String(text.prefix(maximumCharacters))
        guard !sample.isEmpty else { return [:] }
        let stopWords = stopWords(for: language(of: sample))

        var counts: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sample
        tokenizer.enumerateTokens(in: sample.startIndex..<sample.endIndex) { range, _ in
            for word in IdentifierSplitter.words(String(sample[range])) {
                guard isIndexable(word), !stopWords.contains(word) else { continue }
                counts[word, default: 0] += 1
            }
            return true
        }
        return counts
    }

    /// `"de"` or `"en"`; English when the text is neither or too short to tell.
    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.german, .english]
        recognizer.processString(String(text.prefix(2_000)))
        return recognizer.dominantLanguage == .german ? "de" : "en"
    }

    private static func isIndexable(_ word: String) -> Bool {
        guard (minimumLength...maximumLength).contains(word.count) else { return false }
        return word.contains { $0.isLetter }
    }

    private static func stopWords(for language: String) -> Set<String> {
        language == "de" ? german : english
    }

    private static let english: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was",
        "one", "our", "out", "day", "get", "has", "him", "his", "how", "man", "new", "now", "old",
        "see", "two", "way", "who", "boy", "did", "its", "let", "put", "say", "she", "too", "use",
        "that", "with", "have", "this", "will", "your", "from", "they", "know", "want", "been",
        "good", "much", "some", "time", "very", "when", "come", "here", "just", "like", "long",
        "make", "many", "more", "only", "over", "such", "take", "than", "them", "well", "were",
        "what", "which", "their", "there", "would", "about", "could", "other", "these", "into",
    ]

    private static let german: Set<String> = [
        "der", "die", "das", "und", "ist", "nicht", "ein", "eine", "einen", "einem", "einer",
        "den", "dem", "des", "von", "mit", "für", "auf", "auch", "als", "bei", "aus", "nach",
        "wie", "wir", "sie", "ich", "du", "er", "es", "ihr", "sich", "sind", "war", "wird",
        "werden", "wurde", "hat", "haben", "kann", "können", "nur", "noch", "oder", "aber",
        "wenn", "dann", "dass", "diese", "dieser", "dieses", "diesen", "mehr", "sehr", "schon",
        "zum", "zur", "über", "unter", "durch", "gegen", "ohne", "um", "im", "am", "an", "so",
        "hier", "dort", "wieder", "immer", "alle", "alles", "kein", "keine", "man", "mal",
    ]
}

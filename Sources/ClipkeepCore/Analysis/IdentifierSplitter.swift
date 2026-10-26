/// Splits programmer identifiers into lowercase words: `getUserData` and `get_user_data`
/// both become `["get", "user", "data"]`. Digits stay attached to the word before them.
public enum IdentifierSplitter {
    public static func words(_ identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(identifier)

        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character == "." {
                flush(&current, into: &words)
                continue
            }
            if character.isUppercase, !current.isEmpty {
                let previousIsLower = index > 0 && !characters[index - 1].isUppercase
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                // "URLParser" -> "url", "parser": split before the last capital of an acronym.
                if previousIsLower || nextIsLower { flush(&current, into: &words) }
            }
            current.append(character)
        }
        flush(&current, into: &words)
        return words
    }

    private static func flush(_ current: inout String, into words: inout [String]) {
        if !current.isEmpty { words.append(current.lowercased()) }
        current = ""
    }
}

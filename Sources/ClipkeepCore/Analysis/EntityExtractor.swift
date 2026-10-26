import Foundation

public enum EntityKind: String, Sendable, Equatable {
    case domain
    case repo
    case ticket
    case email
    case path
    case identifier
}

public struct Entity: Sendable, Equatable, Hashable {
    public let kind: EntityKind
    public let value: String

    public init(kind: EntityKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// Pulls structured hints out of copied text. Used later for sessions and topics, so the output
/// is deliberately small, deduplicated and capped.
public enum EntityExtractor {
    /// Longest prefix that is analysed, in UTF-8 bytes; the rest of a huge paste adds cost but no
    /// new context. The cut is moved back to whitespace so no token is analysed half.
    static let analysedBytes = 64 * 1024
    static let maximumEntities = 50

    private static let urlPattern = regex(
        #"(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]{0,31}://[^\s<>"'`)\]]+"#)
    private static let emailPattern = regex(
        #"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]{1,64}@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,})(?![A-Za-z0-9:])"#
    )
    private static let ticketPattern = regex(
        #"(?<![A-Za-z0-9\-])([A-Z][A-Z0-9]{1,9})-(\d{1,6})(?![A-Za-z0-9\-])"#)
    // A path segment may hold one space when the word after it is followed by a slash
    // ("My Documents/file.txt"); running prose does not match that shape.
    private static let pathPattern = regex(
        #"(?<![\w/:.])(?:~|\.{1,2})?/[\w.\-]+(?: [\w.\-]+(?=/))?(?:/[\w.\-]+(?: [\w.\-]+(?=/))?)+"#)
    private static let identifierPattern = regex(
        #"\b(?:[a-z][a-z0-9]*(?:[A-Z][a-z0-9]+)+|[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+|[a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b"#
    )
    private static let ticketPrefixesToIgnore: Set<String> = [
        "UTF", "SHA", "ISO", "HTTP", "TLS", "SSL", "AES", "RSA", "GPT", "MD", "TCP", "UDP", "IPV",
        "COVID", "ES", "PEP", "RFC", "WCAG", "ECMA", "IEC", "EN", "DIN", "CVE", "CWE",
    ]
    private static let brandNames: Set<String> = [
        "JavaScript", "TypeScript", "YouTube", "iPhone", "iPad", "iMessage", "McDonald", "GitHub",
        "GitLab", "LinkedIn", "PostgreSQL", "OpenAI", "macOS", "iOS", "WhatsApp", "PayPal",
    ]
    private static let codeHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]
    private static let reservedRepoOwners: Set<String> = [
        "orgs", "settings", "marketplace", "features", "topics", "sponsors", "apps", "login",
        "notifications", "pulls", "issues", "explore", "search", "about", "pricing", "users",
    ]
    private static let repoPathMarkers: Set<String> = [
        "-", "tree", "blob", "issues", "pull", "pulls", "merge_requests", "commit", "commits",
        "releases", "actions", "wiki", "pipelines",
    ]

    public static func extract(from text: String) -> [Entity] {
        let sample = analysedPrefix(of: text)
        var found: [Entity] = []

        for url in matches(urlPattern, in: sample).map(trimTrailingPunctuation) {
            guard let components = URLComponents(string: url), let host = components.host else {
                continue
            }
            let domain = host.lowercased().replacingOccurrences(
                of: "www.", with: "", options: .anchored)
            found.append(Entity(kind: .domain, value: domain))
            if let repo = repository(domain: domain, path: components.path) {
                found.append(Entity(kind: .repo, value: repo))
            }
        }

        // Tickets live in URLs too (".../browse/ABC-12"); everything else is read without URLs so
        // credentials like "user:pw@host" are not mistaken for e-mail addresses.
        let withoutURLs = urlPattern.stringByReplacingMatches(
            in: sample, range: NSRange(sample.startIndex..., in: sample), withTemplate: " ")

        for (address, domain) in captures(emailPattern, in: withoutURLs) {
            found.append(Entity(kind: .email, value: address.lowercased()))
            found.append(Entity(kind: .domain, value: domain.lowercased()))
        }
        for (ticket, prefix, number) in ticketCandidates(in: sample)
        where isTicket(prefix: prefix, number: number) {
            found.append(Entity(kind: .ticket, value: ticket))
        }
        for path in matches(pathPattern, in: withoutURLs) {
            found.append(Entity(kind: .path, value: path))
        }
        for identifier in matches(identifierPattern, in: withoutURLs)
        where identifier.count >= 6 && !brandNames.contains(identifier) {
            found.append(Entity(kind: .identifier, value: identifier))
        }

        var seen = Set<Entity>()
        return found.filter { seen.insert($0).inserted }.prefix(maximumEntities).map { $0 }
    }

    private static func analysedPrefix(of text: String) -> String {
        guard text.utf8.count > analysedBytes else { return text }
        let bytes = Array(text.utf8.prefix(analysedBytes))
        let cut = String(decoding: bytes, as: UTF8.self)
        // Drop the last, possibly incomplete token (and any scalar split by the byte cut).
        guard let lastBreak = cut.lastIndex(where: { $0.isWhitespace }) else { return "" }
        return String(cut[..<lastBreak])
    }

    private static func repository(domain: String, path: String) -> String? {
        guard codeHosts.contains(domain) else { return nil }
        var segments = path.split(separator: "/").map(String.init)
        if let marker = segments.firstIndex(where: { repoPathMarkers.contains($0) }) {
            segments = Array(segments[..<marker])
        }
        // GitHub repos are always owner/name; GitLab allows subgroups before the name.
        if domain != "gitlab.com" { segments = Array(segments.prefix(2)) }
        guard segments.count >= 2, !reservedRepoOwners.contains(segments[0].lowercased()) else {
            return nil
        }
        var name = segments[segments.count - 1]
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        segments[segments.count - 1] = name
        guard segments.allSatisfy({ !$0.isEmpty }) else { return nil }
        return "\(domain)/\(segments.joined(separator: "/").lowercased())"
    }

    private static func isTicket(prefix: String, number: String) -> Bool {
        guard !ticketPrefixesToIgnore.contains(prefix) else { return false }
        // "ES-2022" or "AB-1999" are years and standards, not issue keys.
        if prefix.count == 2, number.count == 4, let year = Int(number),
            (1990...2099).contains(year)
        {
            return false
        }
        return true
    }

    private static func trimTrailingPunctuation(_ url: String) -> String {
        String(url.reversed().drop(while: { ".,;:!?".contains($0) }).reversed())
    }

    private static func ticketCandidates(in text: String) -> [(String, String, String)] {
        ticketPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            result in
            guard let whole = Range(result.range, in: text),
                let prefix = Range(result.range(at: 1), in: text),
                let number = Range(result.range(at: 2), in: text)
            else { return nil }
            return (String(text[whole]), String(text[prefix]), String(text[number]))
        }
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [(
        String, String
    )] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let whole = Range(result.range, in: text),
                let group = Range(result.range(at: 1), in: text)
            else { return nil }
            return (String(text[whole]), String(text[group]))
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants covered by tests, so a failure is a programmer error.
        try! NSRegularExpression(pattern: pattern)
    }
}

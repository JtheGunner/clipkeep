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
    /// Longest prefix that is analysed; the rest of a huge paste adds cost but no new context.
    static let analysedCharacters = 64 * 1024
    static let maximumEntities = 50

    private static let urlPattern = regex(#"(?:https?|ftp)://[^\s<>"'`)\]]+"#)
    private static let emailPattern = regex(
        #"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]{1,64}@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,})"#
    )
    private static let ticketPattern = regex(
        #"(?<![A-Za-z0-9\-])[A-Z][A-Z0-9]{1,9}-\d{1,6}(?![A-Za-z0-9\-])"#)
    private static let pathPattern = regex(#"(?<![\w/:.])(?:~|\.{1,2})?/[\w.\-]+(?:/[\w.\-]+)+"#)
    private static let identifierPattern = regex(
        #"\b(?:[a-z][a-z0-9]*(?:[A-Z][a-z0-9]+)+|[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+|[a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b"#
    )
    private static let ticketPrefixesToIgnore: Set<String> = [
        "UTF", "SHA", "ISO", "HTTP", "TLS", "SSL", "AES", "RSA", "GPT", "MD", "TCP", "UDP", "IPV",
    ]
    private static let codeHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]

    public static func extract(from text: String) -> [Entity] {
        let sample = String(text.prefix(analysedCharacters))
        var found: [Entity] = []

        for url in matches(urlPattern, in: sample) {
            guard let components = URLComponents(string: url), let host = components.host else {
                continue
            }
            let domain = host.lowercased().replacingOccurrences(
                of: "www.", with: "", options: .anchored)
            found.append(Entity(kind: .domain, value: domain))
            if codeHosts.contains(domain) {
                let segments = components.path.split(separator: "/").prefix(2)
                if segments.count == 2 {
                    let name = segments[1].replacingOccurrences(of: ".git", with: "")
                    found.append(Entity(kind: .repo, value: "\(domain)/\(segments[0])/\(name)"))
                }
            }
        }
        for (address, domain) in captures(emailPattern, in: sample) {
            found.append(Entity(kind: .email, value: address.lowercased()))
            found.append(Entity(kind: .domain, value: domain.lowercased()))
        }
        for ticket in matches(ticketPattern, in: sample) {
            let prefix = String(ticket.prefix(while: { $0 != "-" }))
            if !ticketPrefixesToIgnore.contains(prefix) {
                found.append(Entity(kind: .ticket, value: ticket))
            }
        }
        // Remove URLs first so their path segments are not reported as file paths.
        let withoutURLs = urlPattern.stringByReplacingMatches(
            in: sample, range: NSRange(sample.startIndex..., in: sample), withTemplate: " ")
        for path in matches(pathPattern, in: withoutURLs) {
            found.append(Entity(kind: .path, value: path))
        }
        for identifier in matches(identifierPattern, in: withoutURLs) where identifier.count >= 6 {
            found.append(Entity(kind: .identifier, value: identifier))
        }

        var seen = Set<Entity>()
        return found.filter { seen.insert($0).inserted }.prefix(maximumEntities).map { $0 }
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

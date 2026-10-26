import Foundation

/// Cleans window titles and browser URLs before they are stored.
public enum ContextSanitizer {
    static let maximumTitleLength = 200
    static let maximumURLLength = 500

    /// Single line, trimmed and shortened; nil when nothing is left.
    public static func title(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        // Control, bidirectional and zero-width characters could spoof what is displayed later.
        let visible = String(
            String.UnicodeScalarView(
                lines.joined(separator: " ").unicodeScalars.filter {
                    $0.properties.generalCategory != .control
                        && $0.properties.generalCategory != .format
                }))
        guard !visible.isEmpty else { return nil }
        return String(visible.prefix(maximumTitleLength))
    }

    /// Keeps scheme, host, port and path of web addresses. Credentials, query and fragment are
    /// dropped because they often carry tokens. Other schemes (about:, file:) yield nil.
    public static func url(_ raw: String?) -> String? {
        guard let raw,
            var components = URLComponents(
                string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.scheme = scheme
        components.host = host.lowercased()
        guard let cleaned = components.string, cleaned.count <= maximumURLLength else { return nil }
        return cleaned
    }
}

/// Tells mail addresses from SSH targets, which have the same shape.
enum MailAddress {
    /// Account names that stand for a login on a server, not a person.
    private static let loginNames: Set<String> = ["git", "root", "ubuntu", "ec2-user", "pi"]

    /// Whether `address` ("user@host") looks like an SSH target such as `git@github.com`.
    static func isShellLogin(_ address: String) -> Bool {
        guard let separator = address.firstIndex(of: "@") else { return false }
        return loginNames.contains(address[..<separator].lowercased())
    }
}

public enum ContentKind: String, Sendable, Equatable, CaseIterable {
    case text
    case url
    case email
    case path
    case command
    case json
    case stacktrace
    case code
    case number
}

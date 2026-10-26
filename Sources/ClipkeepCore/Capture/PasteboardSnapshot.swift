import Foundation

/// What was on the pasteboard at one `changeCount`, reduced to what the capture pipeline needs.
public struct PasteboardSnapshot: Sendable, Equatable {
    public let changeCount: Int
    /// Raw pasteboard type identifiers, such as `public.utf8-plain-text`.
    public let types: Set<String>
    public let text: String?
    /// Absolute URL strings of `public.url` items.
    public let urls: [String]
    /// File system paths of `public.file-url` items.
    public let filePaths: [String]

    public init(
        changeCount: Int, types: Set<String> = [], text: String? = nil, urls: [String] = [],
        filePaths: [String] = []
    ) {
        self.changeCount = changeCount
        self.types = types
        self.text = text
        self.urls = urls
        self.filePaths = filePaths
    }
}

/// Source of pasteboard snapshots; the system implementation lives in the app target.
public protocol PasteboardReading: Sendable {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
}

/// The app that most likely produced the current copy.
public protocol SourceAppProviding: Sendable {
    func currentSource() -> CopyContext
}

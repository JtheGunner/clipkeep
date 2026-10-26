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

/// Source of pasteboard snapshots.
public protocol PasteboardReading: Sendable {
    var changeCount: Int { get }
    /// A consistent view of the pasteboard, or nil when it changed while it was read; the next
    /// poll then picks the new content up.
    func snapshot() -> PasteboardSnapshot?
}

/// The apps that were frontmost while a copy may have happened.
public protocol SourceAppProviding: Sendable {
    /// Apps frontmost between `start` and `end`, oldest first. The first one was frontmost at
    /// `start`. Never empty in practice; an empty result means the source is unknown.
    func sources(from start: Date, to end: Date) -> [CopyContext]
}

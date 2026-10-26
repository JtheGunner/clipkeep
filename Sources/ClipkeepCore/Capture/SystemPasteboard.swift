import AppKit
import Foundation

/// Reads an `NSPasteboard` (the general one by default). Reads are bracketed by `changeCount`, so
/// a copy that lands in the middle is never combined with the types of the previous one.
public struct SystemPasteboard: PasteboardReading, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> PasteboardSnapshot? {
        let before = pasteboard.changeCount
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        // Content that will be skipped anyway is not even read into memory.
        guard CaptureConfiguration.skipReason(forTypes: types) == nil else {
            return pasteboard.changeCount == before
                ? PasteboardSnapshot(changeCount: before, types: types) : nil
        }
        let text = pasteboard.string(forType: .string)
        let urls = readURLs(fileURLsOnly: false).filter { !$0.isFileURL }.map(\.absoluteString)
        let filePaths = readURLs(fileURLsOnly: true).map(\.path)
        guard pasteboard.changeCount == before else { return nil }
        return PasteboardSnapshot(
            changeCount: before, types: types, text: text, urls: urls, filePaths: filePaths)
    }

    private func readURLs(fileURLsOnly: Bool) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: fileURLsOnly]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

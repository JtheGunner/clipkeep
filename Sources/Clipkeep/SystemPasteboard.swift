import AppKit
import ClipkeepCore

/// Reads the general pasteboard. `NSPasteboard` is safe to read from a background queue.
struct SystemPasteboard: PasteboardReading, @unchecked Sendable {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let urls = readURLs(fileURLsOnly: false).filter { !$0.isFileURL }.map(\.absoluteString)
        let filePaths = readURLs(fileURLsOnly: true).map(\.path)
        return PasteboardSnapshot(
            changeCount: pasteboard.changeCount, types: types,
            text: pasteboard.string(forType: .string), urls: urls, filePaths: filePaths)
    }

    private func readURLs(fileURLsOnly: Bool) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: fileURLsOnly]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// The frontmost app at the time of the copy, which is the app the user copied from.
struct FrontmostApplicationSource: SourceAppProviding {
    func currentSource() -> CopyContext {
        let app = NSWorkspace.shared.frontmostApplication
        return CopyContext(appBundleID: app?.bundleIdentifier, appName: app?.localizedName)
    }
}

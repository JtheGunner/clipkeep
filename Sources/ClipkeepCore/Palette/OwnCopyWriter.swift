import AppKit

/// Puts text on the pasteboard on behalf of Clipkeep. The copy carries a marker type, so the
/// capture pipeline recognises it as its own and does not store it a second time.
public struct OwnCopyWriter: @unchecked Sendable {
    public static let markerType = "li.wuermli.clipkeep.OwnCopy"

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    public func copy(_ text: String) -> Bool {
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(Self.markerType))
        return wrote
    }
}

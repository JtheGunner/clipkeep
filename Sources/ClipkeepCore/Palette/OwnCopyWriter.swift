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
        // Both types are declared in one step: only that call changes the pasteboard's change
        // count, so a poll can never see the text without the marker.
        let marker = NSPasteboard.PasteboardType(Self.markerType)
        pasteboard.declareTypes([.string, marker], owner: nil)
        pasteboard.setData(Data(), forType: marker)
        return pasteboard.setString(text, forType: .string)
    }
}

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

    /// Puts a secret on the pasteboard: marked as concealed and transient so clipboard managers
    /// skip it, kept off Universal Clipboard, and removed again after `clearAfter` seconds unless
    /// something else was copied in the meantime.
    @discardableResult
    public func copySecret(_ text: String, clearAfter: TimeInterval = 60) -> Bool {
        let marker = NSPasteboard.PasteboardType(Self.markerType)
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        // The text goes last, so a poll between the steps never sees it without its markers.
        for type in [marker, concealed, transient] { pasteboard.setData(Data(), forType: type) }
        guard pasteboard.setString(text, forType: .string) else { return false }
        let count = pasteboard.changeCount
        let pasteboard = pasteboard
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
        return true
    }
}

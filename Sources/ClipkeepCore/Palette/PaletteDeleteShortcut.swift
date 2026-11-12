import AppKit
import Carbon.HIToolbox

/// Command+Delete in the palette: deletes the selected snippet in snippet mode and otherwise stays
/// a text edit of the query.
public enum PaletteDeleteShortcut {
    public enum Decision: Sendable, Equatable {
        /// Not the shortcut here: the key goes on to the search field.
        case notShortcut
        /// Delete the selected snippet.
        case delete
        /// Swallow the key without deleting, so it never edits the query in snippet mode.
        case consume
    }

    /// Lock and function-key flags (Caps Lock, Fn, numeric pad) never change the meaning.
    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .shift, .option, .control,
    ]

    /// A held key repeats: only the first press deletes, so holding it cannot remove a run of
    /// snippets one after another.
    public static func decision(
        keyCode: Int, modifiers: NSEvent.ModifierFlags, isRepeat: Bool, inSnippetMode: Bool
    ) -> Decision {
        guard inSnippetMode, keyCode == kVK_Delete,
            modifiers.intersection(relevantModifiers) == .command
        else { return .notShortcut }
        return isRepeat ? .consume : .delete
    }
}

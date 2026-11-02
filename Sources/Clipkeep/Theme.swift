import AppKit

/// Layout constants shared by all windows. Spacing sits on a 4-pt grid so every window lines up the
/// same way.
enum Metrics {
    enum Space {
        /// Gap between a title and its subtitle.
        static let xxs: CGFloat = 2
        /// Inner margin of a list row.
        static let xs: CGFloat = 4
        /// Default gap between neighbouring controls.
        static let s: CGFloat = 8
        /// Margin between a window edge and its content; gap between groups.
        static let m: CGFloat = 12
        /// Margin of a dialog.
        static let l: CGFloat = 16
    }

    enum Radius {
        static let panel: CGFloat = 12
    }

    enum Row {
        static let entry: CGFloat = 40
        static let session: CGFloat = 40
        static let day: CGFloat = 28
        static let palette: CGFloat = 44
    }

    enum Control {
        /// Height of the bar that holds the history window's mode switch, filter and search.
        static let bar: CGFloat = 28
        /// Height of the palette's search field.
        static let paletteField: CGFloat = 28
    }

    enum Pane {
        static let outlineMinWidth: CGFloat = 240
        static let listMinHeight: CGFloat = 120
        static let infoHeight: CGFloat = 152
        static let sampleMinHeight: CGFloat = 180
    }

    enum Window {
        static let history = NSSize(width: 1_100, height: 680)
        static let historyMin = NSSize(width: 800, height: 480)
        static let importer = NSSize(width: 640, height: 520)
        static let importerMin = NSSize(width: 520, height: 400)
        static let paletteWidth: CGFloat = 640
    }

    /// Inner margin of the read-only text views.
    static let textInset = NSSize(width: Space.xs, height: Space.s)
}

/// The fonts of the user interface, by role.
enum Typography {
    static var paletteInput: NSFont { NSFont.systemFont(ofSize: 18) }
    static var paletteTitle: NSFont { NSFont.systemFont(ofSize: 14) }
    static var sectionTitle: NSFont { NSFont.boldSystemFont(ofSize: 13) }
    static var detail: NSFont { NSFont.systemFont(ofSize: 12) }
    static var caption: NSFont { NSFont.systemFont(ofSize: 11) }
    static var mono: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }
    static var monoSmall: NSFont { NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }

    static func title(weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: 13, weight: weight)
    }
}

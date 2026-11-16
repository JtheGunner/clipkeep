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
        static let card: CGFloat = 10
    }

    enum Row {
        static let entry: CGFloat = 44
        static let session: CGFloat = 40
        static let day: CGFloat = 28
        static let palette: CGFloat = 44
    }

    enum Control {
        /// Side of the box every sidebar icon sits in.
        static let icon: CGFloat = 20
        /// Side of the box of a row's disclosure chevron.
        static let disclosure: CGFloat = 12
        /// Height of the palette's search field.
        static let paletteField: CGFloat = 28
    }

    enum Pane {
        static let outlineMinWidth: CGFloat = 272
        static let outlineMaxWidth: CGFloat = 400
        /// Moves a parent row (day, topic, "Alle Einträge") left of the cell's edge.
        static let parentInset: CGFloat = -4
        /// Gap between a child row's icon and its text; a little tighter than a parent's.
        static let childIconGap: CGFloat = 6
        static let parentIconSize: CGFloat = 15
        static let childIconSize: CGFloat = 13
        static let listMinHeight: CGFloat = 120
        /// The list pane with its header, so the header never reaches the toolbar.
        static let listPaneMinHeight: CGFloat = 200
        static let infoHeight: CGFloat = 152
        static let infoMinHeight: CGFloat = 80
        static let textMinHeight: CGFloat = 80
        static let sampleMinHeight: CGFloat = 180
    }

    enum Window {
        static let history = NSSize(width: 1_100, height: 680)
        static let historyMin = NSSize(width: 800, height: 480)
        static let explorer = NSSize(width: 900, height: 620)
        static let explorerMin = NSSize(width: 640, height: 420)
        static let importer = NSSize(width: 640, height: 520)
        static let importerMin = NSSize(width: 520, height: 400)
        static let paletteWidth: CGFloat = 640
    }

    /// Inner margin of the read-only text views.
    static let textInset = NSSize(width: Space.xs, height: Space.s)

    /// Inner margin of the text in a card.
    static let cardTextInset = NSSize(width: Space.m, height: Space.s)
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

/// A view filled with a dynamic colour that follows light and dark appearance.
final class BackgroundView: NSView {
    private let color: NSColor

    init(color: NSColor, cornerRadius: CGFloat = 0) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}

/// SF Symbols used across the windows.
enum Symbols {
    static func image(_ name: String, _ description: String?) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    /// The icon of an entry's type in a list row; the tooltip and the VoiceOver label name the type.
    @MainActor static func typeIcon(_ symbol: String, named typeName: String) -> NSView {
        let icon = NSImageView(image: image(symbol, typeName) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Metrics.Pane.parentIconSize, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        icon.toolTip = typeName
        icon.setAccessibilityLabel(typeName)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Metrics.Control.icon),
            icon.heightAnchor.constraint(equalToConstant: Metrics.Control.icon),
        ])
        return icon
    }
}

/// Colours of the syntax highlighting in the snippet explorer, one dynamic colour per token kind
/// that follows light and dark appearance.
enum SyntaxColors {
    static let keyword = dynamic(light: (0.68, 0.14, 0.60), dark: (0.99, 0.37, 0.64))
    static let string = dynamic(light: (0.77, 0.10, 0.09), dark: (0.99, 0.42, 0.36))
    static let number = dynamic(light: (0.11, 0.00, 0.81), dark: (0.82, 0.75, 0.40))
    static let comment = dynamic(light: (0.42, 0.47, 0.52), dark: (0.50, 0.55, 0.60))
    static let op = dynamic(light: (0.25, 0.30, 0.35), dark: (0.80, 0.82, 0.85))
    static let variable = dynamic(light: (0.04, 0.38, 0.58), dark: (0.40, 0.72, 0.90))
    static let key = dynamic(light: (0.20, 0.31, 0.60), dark: (0.55, 0.70, 1.00))
    static let punctuation = dynamic(light: (0.40, 0.40, 0.40), dark: (0.65, 0.65, 0.65))

    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}

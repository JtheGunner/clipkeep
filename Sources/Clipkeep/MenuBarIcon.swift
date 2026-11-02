import AppKit

/// The Clipkeep logo for the menu bar.
enum MenuBarIcon {
    /// The size of the 1x image in points; the 2x file holds twice as many pixels.
    private static let pointSize = NSSize(width: 18, height: 22)

    /// The logo as a template image, which macOS tints for a light or dark menu bar. Nil when the
    /// files are not in the app bundle, for example when the app runs as a bare executable
    /// (`swift run`); the caller then falls back to a symbol.
    static func logo(in bundle: Bundle = .main) -> NSImage? {
        let image = NSImage(size: pointSize)
        for name in ["clipkeep-menubar", "clipkeep-menubar@2x"] {
            guard let url = bundle.url(forResource: name, withExtension: "png"),
                let data = try? Data(contentsOf: url),
                let representation = NSBitmapImageRep(data: data)
            else { continue }
            // Both files describe the same point size; the 2x file just has more pixels.
            representation.size = pointSize
            image.addRepresentation(representation)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }
}

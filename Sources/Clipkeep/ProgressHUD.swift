import AppKit

/// A small floating panel with a spinner and a line of text. Shown while Bitwarden works, so the
/// feedback does not depend on the menu (closed after a click) or on room in the menu bar.
@MainActor
final class ProgressHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: true)
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Shows the panel at the top centre of the screen the pointer is on, which is where the user
    /// just clicked; with several displays the menu bar item exists on each of them, so it
    /// cannot say where to look. Calling it again only changes the text.
    func show(_ text: String) {
        label.stringValue = text
        spinner.startAnimation(nil)
        guard let content = panel.contentView else { return }
        panel.setContentSize(content.fittingSize)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(
                NSPoint(
                    x: area.midX - panel.frame.width / 2, y: area.maxY - panel.frame.height - 8))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }
}

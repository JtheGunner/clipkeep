import AppKit
import ClipkeepCore
import os

/// A panel that can take keyboard input without making Clipkeep the active app.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The floating search palette: type to search, arrows to choose, Return to copy, Esc to close.
@MainActor
final class PaletteController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSWindowDelegate
{
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "palette")
    private static let width: CGFloat = 640
    private static let rowHeight: CGFloat = 44
    private static let visibleRows: CGFloat = 8

    private let search: PaletteSearch
    private let copyWriter: OwnCopyWriter
    private let panel: PalettePanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var rows: [PaletteRow] = []
    private var generation = 0

    init(search: PaletteSearch, copyWriter: OwnCopyWriter = OwnCopyWriter()) {
        self.search = search
        self.copyWriter = copyWriter
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        buildPanel()
    }

    private func buildPanel() {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        field.placeholderString = "Zwischenablage durchsuchen …"
        field.font = .systemFont(ofSize: 18)
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = Self.width - 20
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.selectionHighlightStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(field)
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        field.stringValue = ""
        reload(query: "")
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Upper third of the screen the mouse is on.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        resizePanel()
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - area.height * 0.18))
    }

    private func resizePanel() {
        let shown = min(CGFloat(max(rows.count, 1)), Self.visibleRows)
        let height = 14 + 28 + 10 + shown * Self.rowHeight + 6
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(frame, display: true)
    }

    // MARK: - Searching

    private func reload(query: String) {
        generation += 1
        let current = generation
        let search = search
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try search.rows(for: query) }
            await self?.apply(result, generation: current)
        }
    }

    private func apply(_ result: Result<[PaletteRow], Error>, generation: Int) {
        // A slower, older search must not overwrite a newer one.
        guard generation == self.generation else { return }
        switch result {
        case .success(let found): rows = found
        case .failure(let error):
            Self.logger.error("Search failed: \(String(describing: error), privacy: .public)")
            rows = []
        }
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        if panel.isVisible { resizePanel() }
    }

    func controlTextDidChange(_ notification: Notification) {
        reload(query: field.stringValue)
    }

    // MARK: - Keyboard

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(table.selectedRow + offset, 0), rows.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func chooseSelected() {
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        copyWriter.copy(rows[index].text)
        hide()
    }

    @objc private func rowClicked() {
        chooseSelected()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let row = rows[row]
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: row.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        return stack
    }
}

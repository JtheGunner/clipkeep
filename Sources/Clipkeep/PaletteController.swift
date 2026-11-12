import AppKit
import ClipkeepCore
import os

/// What the palette searches.
enum PaletteMode {
    case history
    case snippets
}

/// A panel that can take keyboard input without making Clipkeep the active app.
private final class PalettePanel: NSPanel {
    /// Offered each key equivalent first; returns whether it handled the key.
    var onKeyEquivalent: (@MainActor (NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    /// Key equivalents reach the window before the field editor, so a handled Command+Delete
    /// never deletes query text. Unhandled, it falls through to the field as usual.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The floating search palette: type to search, arrows to choose, Return to copy, Esc to close,
/// Tab to switch between history and snippets, Command+Delete to delete a snippet.
@MainActor
final class PaletteController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSWindowDelegate
{
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "palette")
    private static let width = Metrics.Window.paletteWidth
    private static let rowHeight = Metrics.Row.palette
    private static let visibleRows: CGFloat = 8

    private let history: any PaletteSource
    private let snippets: any PaletteSource
    private let deleteSnippet: (Int64) throws -> Void
    private let copyWriter: OwnCopyWriter
    private let panel: PalettePanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var rows: [PaletteRow] = []
    private(set) var mode: PaletteMode = .history

    init(
        history: any PaletteSource, snippets: any PaletteSource,
        deleteSnippet: @escaping (Int64) throws -> Void,
        copyWriter: OwnCopyWriter = OwnCopyWriter()
    ) {
        self.history = history
        self.snippets = snippets
        self.deleteSnippet = deleteSnippet
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
        panel.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Metrics.Radius.panel
        background.layer?.masksToBounds = true

        field.placeholderString = Self.placeholder(for: mode)
        field.font = Typography.paletteInput
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = Self.width - 2 * (Metrics.Space.xs + Metrics.Space.s)
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.selectionHighlightStyle = .regular
        table.style = .inset
        // Keyboard focus stays in the search field, so Esc and Return always reach it.
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(field)
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: Metrics.Space.l),
            field.leadingAnchor.constraint(
                equalTo: background.leadingAnchor, constant: Metrics.Space.l),
            field.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -Metrics.Space.l),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Metrics.Space.s),
            scroll.leadingAnchor.constraint(
                equalTo: background.leadingAnchor, constant: Metrics.Space.xs),
            scroll.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -Metrics.Space.xs),
            scroll.bottomAnchor.constraint(
                equalTo: background.bottomAnchor, constant: -Metrics.Space.s),
        ])
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    /// Hides the palette when it is open in `mode`; otherwise shows it in `mode`.
    func toggle(mode: PaletteMode) {
        if isVisible && self.mode == mode {
            hide()
        } else {
            show(mode: mode)
        }
    }

    func show(mode: PaletteMode = .history) {
        setMode(mode)
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
        let screen =
            NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        resizePanel()
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - area.height * 0.18))
    }

    private func resizePanel() {
        let shown = min(CGFloat(max(rows.count, 1)), Self.visibleRows)
        let height =
            Metrics.Space.l + Metrics.Control.paletteField + Metrics.Space.s
            + shown * Self.rowHeight + Metrics.Space.s
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(frame, display: true)
    }

    private static func placeholder(for mode: PaletteMode) -> String {
        switch mode {
        case .history: "Zwischenablage durchsuchen …"
        case .snippets: "Snippets durchsuchen …"
        }
    }

    private func setMode(_ mode: PaletteMode) {
        self.mode = mode
        field.placeholderString = Self.placeholder(for: mode)
    }

    /// Keeps the query, so the same words search the other source.
    private func switchMode() {
        setMode(mode == .history ? .snippets : .history)
        reload(query: field.stringValue)
    }

    // MARK: - Searching

    /// Runs on the main thread: the query is a few milliseconds, and an answer that is always
    /// current means Return can never copy a row of an older query.
    private func reload(query: String, selecting index: Int = 0) {
        let source = mode == .history ? history : snippets
        do {
            rows = try source.rows(for: query, now: Date())
        } catch {
            Self.logger.error("Search failed: \(String(describing: error), privacy: .public)")
            rows = []
        }
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes([min(index, rows.count - 1)], byExtendingSelection: false)
        }
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
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            switchMode()
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

    /// Command+Delete in snippet mode; in history mode it stays a text edit of the query.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        // `isARepeat` is only valid for key events.
        guard event.type == .keyDown else { return false }
        switch PaletteDeleteShortcut.decision(
            keyCode: Int(event.keyCode), modifiers: event.modifierFlags,
            isRepeat: event.isARepeat, inSnippetMode: mode == .snippets)
        {
        case .notShortcut: return false
        case .consume: return true
        case .delete:
            deleteSelectedSnippet()
            return true
        }
    }

    private func deleteSelectedSnippet() {
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        do {
            try deleteSnippet(rows[index].contentID)
        } catch {
            Self.logger.error(
                "Deleting a snippet failed: \(String(describing: error), privacy: .public)")
        }
        reload(query: field.stringValue, selecting: index)
    }

    @objc private func rowClicked() {
        let clicked = table.clickedRow
        guard rows.indices.contains(clicked) else { return }
        table.selectRowIndexes([clicked], byExtendingSelection: false)
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
        title.font = Typography.paletteTitle
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: row.subtitle)
        subtitle.font = Typography.caption
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.Space.xxs
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.Space.xs, left: Metrics.Space.xs, bottom: Metrics.Space.xs,
            right: Metrics.Space.s)
        let icon = Symbols.typeIcon(row.symbolName, named: row.typeName)
        let line = NSStackView(views: [icon, stack])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = Metrics.Space.s
        line.edgeInsets = NSEdgeInsets(
            top: 0, left: Metrics.Space.s, bottom: 0, right: 0)
        return line
    }
}

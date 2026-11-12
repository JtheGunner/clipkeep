import AppKit
import ClipkeepCore
import os

/// Lists every snippet with filters (language, topic, text) and sortable columns, shows the
/// selected one in full and copies or deletes it.
@MainActor
final class SnippetExplorerWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "snippets")

    /// More than anyone collects by hand; the explorer keeps them all in memory.
    private static let loadLimit = 10_000

    private let store: SnippetStore
    private let copyWriter: OwnCopyWriter
    private let window: NSWindow
    private let searchField = NSSearchField()
    private let languageMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let topicMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let detailView = NSTextView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Kopieren", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Löschen …", target: nil, action: nil)

    private var all: [Snippet] = []
    private var shown: [Snippet] = []
    private var topicByID: [Int64: String] = [:]
    private var query = SnippetExplorerQuery()
    private var isRebuildingMenus = false

    private static let languages: [(SnippetLanguage?, String)] = [
        (nil, "Alle Sprachen"), (.shell, "Shell"), (.sql, "SQL"), (.yaml, "YAML"),
    ]

    private static let relativeDates: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let absoluteDates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(store: SnippetStore, copyWriter: OwnCopyWriter = OwnCopyWriter()) {
        self.store = store
        self.copyWriter = copyWriter
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.Window.explorer),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: true)
        super.init()
        build()
    }

    func show() {
        searchField.stringValue = ""
        query = SnippetExplorerQuery()
        languageMenu.selectItem(at: 0)
        table.sortDescriptors = [Self.descriptor(for: query)]
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    // MARK: - Building

    private func build() {
        window.title = "Snippets"
        window.minSize = Metrics.Window.explorerMin
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("SnippetExplorer")
        window.center()

        searchField.placeholderString = "Snippets durchsuchen"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (_, title) in Self.languages { languageMenu.addItem(withTitle: title) }
        languageMenu.target = self
        languageMenu.action = #selector(languageChanged)
        topicMenu.target = self
        topicMenu.action = #selector(topicChanged)
        topicMenu.addItem(withTitle: "Alle Themen")
        topicMenu.toolTip = "Das Thema steht im Text: Programm, Tabelle oder Schlüssel"

        let bar = NSStackView(views: [searchField, languageMenu, topicMenu])
        bar.orientation = .horizontal
        bar.spacing = Metrics.Space.s

        configureTable()
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        detailView.isEditable = false
        detailView.isRichText = false
        detailView.font = Typography.mono
        detailView.textContainerInset = Metrics.textInset
        detailView.isVerticallyResizable = true
        detailView.autoresizingMask = [.width]
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailView
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder

        infoLabel.font = Typography.caption
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = Typography.caption
        countLabel.textColor = .secondaryLabelColor

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [countLabel, spacer, deleteButton, copyButton])
        footer.orientation = .horizontal
        footer.spacing = Metrics.Space.s

        let content = NSStackView(views: [bar, tableScroll, infoLabel, detailScroll, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Metrics.Space.s
        content.edgeInsets = NSEdgeInsets(
            top: Metrics.Space.m, left: Metrics.Space.m, bottom: Metrics.Space.m,
            right: Metrics.Space.m)
        for view in [bar, tableScroll, infoLabel, detailScroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: content.widthAnchor, constant: -2 * Metrics.Space.m
            ).isActive = true
        }
        detailScroll.heightAnchor.constraint(equalToConstant: Metrics.Pane.infoHeight).isActive =
            true
        tableScroll.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Metrics.Pane.listMinHeight
        )
        .isActive = true
        window.contentView = content
        updateSelectionState()
    }

    private func configureTable() {
        let columns: [(SnippetSortKey, String, CGFloat, CGFloat)] = [
            (.title, "Snippet", 360, 160), (.language, "Sprache", 70, 56),
            (.topic, "Thema", 110, 70), (.lastUsed, "Zuletzt genutzt", 120, 90),
            (.count, "Häufigkeit", 80, 64),
        ]
        for (key, title, width, minWidth) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.resizingMask = key == .title ? .autoresizingMask : .userResizingMask
            // The first click sorts the way a reader expects: names A to Z, the rest biggest
            // or newest first.
            let ascendingFirst = key == .title || key == .language || key == .topic
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: key.rawValue, ascending: ascendingFirst)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [Self.descriptor(for: query)]
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(copySelected)
        table.setAccessibilityLabel("Snippets")
    }

    private static func descriptor(for query: SnippetExplorerQuery) -> NSSortDescriptor {
        NSSortDescriptor(key: query.sortKey.rawValue, ascending: query.ascending)
    }

    // MARK: - Loading and filtering

    private func reload() {
        let selectedID = selectedSnippet?.id
        do {
            all = try store.list(limit: Self.loadLimit)
        } catch {
            Self.logger.error(
                "Loading snippets failed: \(String(describing: error), privacy: .public)")
            all = []
            infoLabel.stringValue = "Snippets konnten nicht geladen werden."
        }
        topicByID = Dictionary(
            all.compactMap { snippet in SnippetTopic.of(snippet).map { (snippet.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        rebuildTopicMenu()
        applyFilters(keeping: selectedID)
    }

    private func rebuildTopicMenu() {
        isRebuildingMenus = true
        defer { isRebuildingMenus = false }
        let topics = SnippetExplorer.topics(in: all, language: query.language)
        // A topic that no longer exists under the chosen language cannot stay selected.
        if let current = query.topic, !topics.contains(where: { $0.name == current }) {
            query.topic = nil
        }
        topicMenu.removeAllItems()
        topicMenu.addItem(withTitle: "Alle Themen")
        topicMenu.lastItem?.representedObject = nil
        for topic in topics {
            topicMenu.addItem(withTitle: "\(topic.name) (\(topic.count))")
            topicMenu.lastItem?.representedObject = topic.name
        }
        if let current = query.topic,
            let index = topicMenu.itemArray.firstIndex(where: {
                ($0.representedObject as? String) == current
            })
        {
            topicMenu.selectItem(at: index)
        } else {
            topicMenu.selectItem(at: 0)
        }
    }

    private func applyFilters(keeping selectedID: Int64? = nil) {
        shown = SnippetExplorer.apply(query, to: all)
        table.reloadData()
        if let selectedID, let row = shown.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        let total = all.count
        countLabel.stringValue =
            shown.count == total
            ? (total == 1 ? "1 Snippet" : "\(total) Snippets")
            : "\(shown.count) von \(total) Snippets"
        if total == 0 {
            infoLabel.stringValue =
                "Noch keine Snippets. Kopierter Shell-, SQL- und YAML-Code erscheint hier automatisch."
        } else if shown.isEmpty {
            infoLabel.stringValue = "Kein Snippet passt zu den Filtern."
        }
        updateSelectionState()
    }

    @objc private func languageChanged() {
        guard !isRebuildingMenus else { return }
        query.language = Self.languages[languageMenu.indexOfSelectedItem].0
        rebuildTopicMenu()
        applyFilters(keeping: selectedSnippet?.id)
    }

    @objc private func topicChanged() {
        guard !isRebuildingMenus else { return }
        query.topic = topicMenu.selectedItem?.representedObject as? String
        applyFilters(keeping: selectedSnippet?.id)
    }

    func controlTextDidChange(_ obj: Notification) {
        query.text = searchField.stringValue
        applyFilters(keeping: selectedSnippet?.id)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Captures add snippets while the window is closed or in the background.
        reload()
    }

    // MARK: - Selection and actions

    private var selectedSnippet: Snippet? {
        let row = table.selectedRow
        return shown.indices.contains(row) ? shown[row] : nil
    }

    private func updateSelectionState() {
        let snippet = selectedSnippet
        copyButton.isEnabled = snippet != nil
        deleteButton.isEnabled = snippet != nil
        guard let snippet else {
            detailView.string = ""
            return
        }
        detailView.string = snippet.text
        var parts = [SnippetExplorerWindowController.languageName(snippet.language)]
        if let topic = topicByID[snippet.id] { parts.append("Thema: \(topic)") }
        parts.append("angelegt \(Self.absoluteDates.string(from: snippet.createdAt))")
        parts.append("zuletzt genutzt \(Self.absoluteDates.string(from: snippet.lastCopiedAt))")
        parts.append(
            snippet.origin == .history ? "aus dem Verlauf übernommen" : "automatisch erfasst")
        if let app = snippet.appName { parts.append("aus \(app)") }
        infoLabel.stringValue = parts.joined(separator: " · ")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionState()
    }

    @objc private func copySelected() {
        guard let snippet = selectedSnippet else { return }
        copyWriter.copy(snippet.text)
    }

    @objc private func deleteSelected() {
        guard let snippet = selectedSnippet else { return }
        let alert = NSAlert()
        alert.messageText = "Snippet löschen?"
        alert.informativeText =
            "Das Snippet wird entfernt und nicht wieder automatisch erfasst. Über „Als Snippet speichern“ im Verlauf lässt es sich zurückholen."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.performDelete(snippet) }
        }
    }

    private func performDelete(_ snippet: Snippet) {
        do {
            _ = try store.delete(id: snippet.id)
        } catch {
            Self.logger.error(
                "Deleting a snippet failed: \(String(describing: error), privacy: .public)")
            infoLabel.stringValue = "Das Snippet konnte nicht gelöscht werden."
            return
        }
        reload()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, shown.indices.contains(row) else { return nil }
        let identifier = tableColumn.identifier
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? Self.makeCell(identifier)
        let snippet = shown[row]
        switch SnippetSortKey(rawValue: identifier.rawValue) {
        case .title: cell.stringValue = PaletteRow(snippet: snippet).title
        case .language: cell.stringValue = Self.languageName(snippet.language)
        case .topic: cell.stringValue = topicByID[snippet.id] ?? "–"
        case .lastUsed:
            cell.stringValue = Self.relativeDates.localizedString(
                for: snippet.lastCopiedAt, relativeTo: Date())
        case .count: cell.stringValue = "\(snippet.copyCount)×"
        default: cell.stringValue = ""
        }
        return cell
    }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
            let sortKey = SnippetSortKey(rawValue: key)
        else { return }
        query.sortKey = sortKey
        query.ascending = descriptor.ascending
        applyFilters(keeping: selectedSnippet?.id)
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
        let cell = NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.lineBreakMode = .byTruncatingTail
        cell.font =
            identifier.rawValue == SnippetSortKey.title.rawValue
            ? Typography.mono : Typography.detail
        cell.textColor =
            identifier.rawValue == SnippetSortKey.title.rawValue
            ? .labelColor : .secondaryLabelColor
        return cell
    }

    private static func languageName(_ language: SnippetLanguage) -> String {
        switch language {
        case .shell: "Shell"
        case .sql: "SQL"
        case .yaml: "YAML"
        }
    }
}

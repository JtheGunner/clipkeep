import AppKit
import ClipkeepCore
import os

/// Lists every snippet with filters (language, topic, text) and sortable columns, shows the
/// selected one in full and copies or deletes it.
@MainActor
final class SnippetExplorerWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate
{
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "snippets")

    /// More than anyone collects by hand; the explorer keeps them all in memory.
    private static let loadLimit = 10_000

    private let store: SnippetStore
    private let creator: SnippetCreator
    private let copyWriter: OwnCopyWriter
    private let window: NSWindow
    private let searchField = NSSearchField()
    private let languageMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let topicMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let detailView = NSTextView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let variantMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commentField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Kopieren", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Löschen …", target: nil, action: nil)
    private let newButton = NSButton(title: "Neu …", target: nil, action: nil)

    private var all: [Snippet] = []
    private var shown: [Snippet] = []
    private var topicByID: [Int64: String] = [:]
    private var query = SnippetExplorerQuery()
    private var isRebuildingMenus = false
    private var loadFailed = false
    /// The variants of the selected snippet, newest first; empty when there is no selection or
    /// the lookup failed, in which case only the representative text is offered.
    private var variants: [SnippetVariant] = []
    /// The snippet whose comment the field shows, so an edit is saved to that snippet even if
    /// the selection moves before the edit ends.
    private var commentSnippet: Snippet?
    /// True while a comment is being saved; stops the reload that follows from flushing again.
    private var isCommittingComment = false
    /// A message the next selection refresh shows after it has rewritten the info label.
    private var noticeAfterRefresh: String?
    private var isFlushingComment = false
    /// The open "add snippet" sheet; while it exists no second one opens.
    private var createSheet: SnippetCreateSheetController?

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
        creator = SnippetCreator(store: store)
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
        infoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        variantMenu.target = self
        variantMenu.action = #selector(variantChanged)
        variantMenu.font = Typography.caption
        variantMenu.toolTip = "Die Variante, die angezeigt und mit „Kopieren“ kopiert wird"
        variantMenu.setContentHuggingPriority(.required, for: .horizontal)
        variantMenu.isHidden = true
        let infoRow = NSStackView(views: [infoLabel, variantMenu])
        infoRow.orientation = .horizontal
        infoRow.spacing = Metrics.Space.s
        commentField.placeholderString = "Kommentar hinzufügen"
        commentField.font = Typography.caption
        commentField.delegate = self
        commentField.lineBreakMode = .byTruncatingTail
        commentField.cell?.usesSingleLineMode = true
        commentField.setAccessibilityLabel("Kommentar")
        countLabel.font = Typography.caption
        countLabel.textColor = .secondaryLabelColor

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newButton.target = self
        newButton.action = #selector(newSnippet)
        newButton.toolTip = "Ein Snippet von Hand hinzufügen"
        let footer = NSStackView(views: [countLabel, spacer, newButton, deleteButton, copyButton])
        footer.orientation = .horizontal
        footer.spacing = Metrics.Space.s

        let content = NSStackView(views: [
            bar, tableScroll, infoRow, commentField, detailScroll, footer,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Metrics.Space.s
        content.edgeInsets = NSEdgeInsets(
            top: Metrics.Space.m, left: Metrics.Space.m, bottom: Metrics.Space.m,
            right: Metrics.Space.m)
        for view in [bar, tableScroll, infoRow, commentField, detailScroll, footer] {
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
            (.created, "Angelegt", 130, 90), (.count, "Häufigkeit", 80, 64),
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

    private func reload(selecting snippetID: Int64? = nil) {
        flushPendingComment()
        let selectedID = snippetID ?? selectedSnippet?.id
        loadFailed = false
        do {
            all = try store.list(limit: Self.loadLimit)
        } catch {
            Self.logger.error(
                "Loading snippets failed: \(String(describing: error), privacy: .public)")
            all = []
            loadFailed = true
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
        flushPendingComment()
        shown = SnippetExplorer.apply(query, to: all)
        table.reloadData()
        // The table keeps a row index across a reload; without this a different snippet could
        // become the selection when the chosen one drops out of the list.
        table.deselectAll(nil)
        if let selectedID, let row = shown.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        let total = all.count
        countLabel.stringValue =
            shown.count == total
            ? (total == 1 ? "1 Snippet" : "\(total) Snippets")
            : "\(shown.count) von \(total) Snippets"
        updateSelectionState()
    }

    /// What the info line says while nothing is selected.
    private var emptySelectionMessage: String {
        if loadFailed { return "Snippets konnten nicht geladen werden." }
        if all.isEmpty {
            return
                "Noch keine Snippets. Kopierter Shell-, SQL- und YAML-Code erscheint hier automatisch."
        }
        return shown.isEmpty ? "Kein Snippet passt zu den Filtern." : ""
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
        // The comment field shares this delegate; typing there must not refilter and reset it.
        guard (obj.object as? NSTextField) !== commentField else { return }
        query.text = searchField.stringValue
        applyFilters(keeping: selectedSnippet?.id)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === commentField else { return }
        commitComment()
    }

    /// Saves the edited comment to the snippet it was loaded for, then reloads so the list and
    /// its search text pick it up, keeping that snippet selected.
    private func commitComment() {
        guard !isCommittingComment, let snippet = commentSnippet else { return }
        let edited = commentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard edited != (snippet.comment ?? "") else { return }
        isCommittingComment = true
        defer { isCommittingComment = false }
        let notice: String?
        do {
            switch try creator.setComment(id: snippet.id, comment: edited) {
            case .saved, .cleared: notice = nil
            case .notFound: notice = "Das Snippet existiert nicht mehr."
            case .residualSecret:
                // Nothing is stored; the typed text stays in the field so it can be fixed.
                show(
                    notice: "Der Kommentar enthält ein Geheimnis, das nicht entfernt werden konnte."
                )
                return
            }
        } catch {
            Self.logger.error(
                "Saving a snippet comment failed: \(String(describing: error), privacy: .public)")
            show(notice: "Der Kommentar konnte nicht gespeichert werden.")
            return
        }
        reload()
        if let notice { show(notice: notice) }
    }

    /// Shows a message in the info label; a refresh that is already running shows it afterwards.
    private func show(notice: String) {
        infoLabel.stringValue = notice
        if isFlushingComment { noticeAfterRefresh = notice }
    }

    /// Commits a comment edit that is still in progress to the snippet it was started on. Every
    /// path that rewrites the list, the selection or the comment field calls this first, so no
    /// edit depends on end-editing firing before the field is repopulated. Ending editing sends
    /// `controlTextDidEndEditing`, which runs `commitComment`.
    private func flushPendingComment() {
        guard !isCommittingComment, commentField.currentEditor() != nil else { return }
        isFlushingComment = true
        defer { isFlushingComment = false }
        window.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window mid-edit must not drop the comment being typed.
        flushPendingComment()
    }

    func windowDidResignKey(_ notification: Notification) {
        // The app can quit while the window is in the background, without a close; save the
        // edit now. The flush does nothing while a commit runs or no edit is active.
        flushPendingComment()
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
        // The table selection can change under an active comment edit; save it to its snippet
        // before the field is repopulated for the new selection.
        flushPendingComment()
        defer {
            if let notice = noticeAfterRefresh {
                infoLabel.stringValue = notice
                noticeAfterRefresh = nil
            }
        }
        let snippet = selectedSnippet
        copyButton.isEnabled = snippet != nil
        deleteButton.isEnabled = snippet != nil
        commentSnippet = snippet
        commentField.isEnabled = snippet != nil
        commentField.stringValue = snippet?.comment ?? ""
        loadVariants(of: snippet)
        guard let snippet else {
            detailView.string = ""
            infoLabel.stringValue = emptySelectionMessage
            return
        }
        showDetailText(of: snippet)
        infoLabel.stringValue = infoLine(of: snippet)
    }

    /// The info line for the selected snippet, led by the syntax check of the displayed variant.
    private func infoLine(of snippet: Snippet) -> String {
        var parts: [String] = []
        let check = SnippetValidator.check(displayedText(of: snippet), language: snippet.language)
        if let status = check.statusText { parts.append(status) }
        parts.append(SnippetExplorerWindowController.languageName(snippet.language))
        if snippet.variantCount > 1 { parts.append("\(snippet.variantCount) Varianten") }
        if let topic = topicByID[snippet.id] { parts.append("Thema: \(topic)") }
        parts.append("angelegt \(Self.absoluteDates.string(from: snippet.createdAt))")
        parts.append("zuletzt genutzt \(Self.absoluteDates.string(from: snippet.lastCopiedAt))")
        parts.append(Self.originName(snippet.origin))
        if let app = snippet.appName { parts.append("aus \(app)") }
        return parts.joined(separator: " · ")
    }

    /// Fills the variant menu for the selected snippet and selects its first entry, the
    /// representative. A failing lookup leaves the menu hidden and the representative alone.
    private func loadVariants(of snippet: Snippet?) {
        variants = []
        variantMenu.removeAllItems()
        variantMenu.isHidden = true
        guard let snippet, snippet.variantCount > 1 else { return }
        do {
            variants = try store.variants(of: snippet.id)
        } catch {
            Self.logger.error(
                "Loading snippet variants failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard variants.count > 1 else {
            variants = []
            return
        }
        // Add items directly: addItem(withTitle:) would replace an item with an equal title and
        // shift every later index away from `variants`.
        for (offset, variant) in variants.enumerated() {
            variantMenu.menu?.addItem(
                NSMenuItem(
                    title: Self.menuTitle(of: variant, position: offset + 1), action: nil,
                    keyEquivalent: ""))
        }
        guard variantMenu.numberOfItems == variants.count else {
            Self.logger.error("Variant menu and variants disagree; showing the representative only")
            variants = []
            variantMenu.removeAllItems()
            return
        }
        variantMenu.selectItem(at: 0)
        variantMenu.isHidden = false
    }

    private static func menuTitle(of variant: SnippetVariant, position: Int) -> String {
        SnippetExplorer.variantMenuTitle(
            position: position, text: variant.text, copyCount: variant.copyCount,
            age: relativeDates.localizedString(for: variant.lastCopiedAt, relativeTo: Date()))
    }

    /// The text of the chosen variant, or of the snippet itself when it has none to choose from.
    /// The detail view and "Kopieren" both read it, so the text shown is the text copied.
    private func displayedText(of snippet: Snippet) -> String {
        let index = variantMenu.indexOfSelectedItem
        guard variants.indices.contains(index) else { return snippet.text }
        return variants[index].text
    }

    @objc private func variantChanged() {
        guard let snippet = selectedSnippet else { return }
        showDetailText(of: snippet)
        // The check follows the variant on display.
        infoLabel.stringValue = infoLine(of: snippet)
    }

    /// Shows the displayed text in the detail view, coloured for the snippet's language. The styling
    /// never changes a character, so the view still holds exactly the text "Kopieren" copies.
    private func showDetailText(of snippet: Snippet) {
        let styled = SnippetSyntaxStyle.attributedString(
            for: displayedText(of: snippet), language: snippet.language)
        detailView.textStorage?.setAttributedString(styled)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionState()
    }

    @objc private func copySelected() {
        guard let snippet = selectedSnippet else { return }
        copyWriter.copy(displayedText(of: snippet))
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

    @objc private func newSnippet() {
        guard createSheet == nil, window.attachedSheet == nil else { return }
        flushPendingComment()
        let controller = SnippetCreateSheetController(creator: creator) { [weak self] outcome in
            self?.finishCreating(outcome)
        }
        createSheet = controller
        controller.present(on: window)
    }

    /// Reloads with the new snippet selected. The filters are cleared so it cannot be hidden by
    /// them; the sort order stays.
    private func finishCreating(_ outcome: SnippetCreateOutcome?) {
        createSheet = nil
        let snippetID: Int64
        var notice: String?
        switch outcome {
        case nil: return
        case .created(let id): snippetID = id
        case .joined(let id, let commentKept):
            snippetID = id
            notice =
                commentKept
                ? "Zu einem bestehenden Snippet hinzugefügt. Der bestehende Kommentar wurde beibehalten."
                : "Zu einem bestehenden Snippet hinzugefügt."
        case .empty, .tooLarge, .residualSecret, .commentResidualSecret: return
        }
        flushPendingComment()
        searchField.stringValue = ""
        languageMenu.selectItem(at: 0)
        query.text = ""
        query.language = nil
        query.topic = nil
        reload(selecting: snippetID)
        if let notice { show(notice: notice) }
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
        case .created: cell.stringValue = Self.absoluteDates.string(from: snippet.createdAt)
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

    private static func originName(_ origin: SnippetOrigin) -> String {
        switch origin {
        case .history: "aus dem Verlauf übernommen"
        case .manual: "von Hand hinzugefügt"
        case .auto: "automatisch erfasst"
        }
    }

    private static func languageName(_ language: SnippetLanguage) -> String {
        switch language {
        case .shell: "Shell"
        case .sql: "SQL"
        case .yaml: "YAML"
        }
    }
}

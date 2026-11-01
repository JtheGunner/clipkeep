import AppKit
import ClipkeepCore
import os

// MARK: - Outline nodes

/// Outline items need object identity, so the value types are wrapped.
private final class DayNode: NSObject {
    var section: DaySection
    var sessions: [SessionNode]

    init(_ section: DaySection) {
        self.section = section
        sessions = section.sessions.map(SessionNode.init)
    }
}

private final class TopicNode: NSObject {
    let summary: TopicSummary
    var sessions: [SessionNode]?
    var isExpanded = false

    init(_ summary: TopicSummary) {
        self.summary = summary
    }
}

private final class SessionNode: NSObject {
    let summary: SessionSummary

    init(_ summary: SessionSummary) {
        self.summary = summary
    }
}

/// The history window: sessions by day or by topic on the left, the entries of the selection in
/// the middle, one entry with its context and score explanation below. The search field looks in
/// whatever is selected, or everywhere when nothing is.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate, NSOutlineViewDataSource,
    NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    NSMenuDelegate
{
    private enum Mode: Int {
        case days
        case topics
    }

    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "history")
    private static let sessionPageSize = 50
    private static let topicPageSize = 100
    private static let entryPageSize = 100
    private static let searchLimit = 200
    private static let nearEnd: CGFloat = 300

    private let browser: HistoryBrowser
    private let search: SearchService
    private let exporter: MarkdownExporter
    private let actions: ItemActions
    private let copyWriter: OwnCopyWriter
    private let topics: TopicService
    private let secrets: SecretParker
    private let bitwarden: BitwardenSync

    private let window: NSWindow
    private let modeControl = NSSegmentedControl(
        labels: ["Tag", "Themen"], trackingMode: .selectOne, target: nil, action: nil)
    private let entityMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchField = NSSearchField()
    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let headerLabel = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let contentView = NSTextView()
    private let infoView = NSTextView()
    private let copyButton = NSButton(title: "Kopieren", target: nil, action: nil)
    private let pinButton = NSButton(title: "Anheften", target: nil, action: nil)
    private let starButton = NSButton(title: "Markieren", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Löschen", target: nil, action: nil)
    private let exportButton = NSButton(title: "Exportieren …", target: nil, action: nil)
    private let undoButton = NSButton(title: "Löschen rückgängig", target: nil, action: nil)
    private let fetchButton = NSButton(title: "Aus Bitwarden abrufen", target: nil, action: nil)
    private let notSecretButton = NSButton(title: "Kein Secret", target: nil, action: nil)

    private var mode = Mode.days
    private var entityChoices: [EntityChoice] = []
    private var entityFilter: EntityFilter?
    private var timeline = DayTimeline()
    private var daysExhausted = false
    private var dayNodes: [DayNode] = []
    private var topicNodes: [TopicNode] = []
    private var topicLimit = HistoryWindowController.topicPageSize
    private var scope = HistoryScope.all
    private var rows: [HistoryRow] = []
    private var entryCursor: SessionEntry?
    private var entriesExhausted = true
    private var detail: EntryDetail?
    private var lastDeletedID: Int64?
    private var baseHeader = ""
    private var exportNote = ""
    private var isExporting = false
    private var searchNote = ""
    private var secretNote = ""
    private var parkedSecret: ParkedSecret?
    private var isWorkingOnSecret = false
    private var isLoading = false
    private var refreshTimer: Timer?
    private var shownChangeToken: String?

    init(
        browser: HistoryBrowser, search: SearchService, actions: ItemActions,
        exporter: MarkdownExporter, topics: TopicService, secrets: SecretParker,
        bitwarden: BitwardenSync,
        copyWriter: OwnCopyWriter = OwnCopyWriter()
    ) {
        self.topics = topics
        self.secrets = secrets
        self.bitwarden = bitwarden
        self.browser = browser
        self.search = search
        self.exporter = exporter
        self.actions = actions
        self.copyWriter = copyWriter
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: true)
        super.init()
        buildWindow()
    }

    // MARK: - Showing

    func show() {
        searchField.stringValue = ""
        lastDeletedID = nil
        reloadEntityMenu()
        reloadLeft()
        startWatchingForChanges()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    // MARK: - Keeping up with changes

    private static let refreshInterval: TimeInterval = 2

    /// Copies, the "Kein Secret" notification action and other writers change the database while
    /// the window is open; a cheap fingerprint tells when the lists are out of date.
    private func startWatchingForChanges() {
        shownChangeToken = try? browser.changeToken()
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfChanged() }
        }
    }

    private func stopWatchingForChanges() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopWatchingForChanges()
    }

    private func refreshIfChanged() {
        guard window.isVisible else { return }
        guard let token = try? browser.changeToken(), token != shownChangeToken else { return }
        // Wait while the user is mid-action; the next tick looks again.
        guard !isLoading, !isWorkingOnSecret, !isExporting, query.isEmpty else { return }
        shownChangeToken = token
        refreshKeepingView()
    }

    /// Reloads the lists and puts selection and scroll positions back.
    private func refreshKeepingView() {
        let outlineOrigin = outlineScroll.contentView.bounds.origin
        let tableOrigin = tableScroll.contentView.bounds.origin
        let keptScope = scope
        let keptContentID =
            rows.indices.contains(table.selectedRow)
            ? rows[table.selectedRow].contentID : nil

        reloadLeft()
        restoreSelection(scope: keptScope)
        reloadHeader()
        outlineScroll.contentView.scroll(to: outlineOrigin)
        outlineScroll.reflectScrolledClipView(outlineScroll.contentView)

        if let keptContentID, let row = rows.firstIndex(where: { $0.contentID == keptContentID }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        tableScroll.contentView.scroll(to: tableOrigin)
        tableScroll.reflectScrolledClipView(tableScroll.contentView)
    }

    private func restoreSelection(scope kept: HistoryScope) {
        for row in 0..<outline.numberOfRows {
            let matches =
                switch (outline.item(atRow: row), kept) {
                case (let node as SessionNode, .session(let id)): node.summary.id == id
                case (let node as DayNode, .day(let day)): node.section.day == day
                case (let node as TopicNode, .topic(let id)): node.summary.id == id
                default: false
                }
            if matches {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
    }

    // MARK: - Building

    private func buildWindow() {
        window.title = "Clipkeep – Verlauf"
        window.minSize = NSSize(width: 800, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ClipkeepHistoryWindow")

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        entityMenu.target = self
        entityMenu.action = #selector(entityChanged)
        searchField.placeholderString = "Suchen (in der Auswahl) …"
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [modeControl, entityMenu, searchField])
        bar.orientation = .horizontal
        bar.spacing = 10

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(buildOutline())
        split.addArrangedSubview(buildRight())
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        // Explicit edges: the bar sits at the top and the split takes all the space below it.
        let content = NSView()
        content.addSubview(bar)
        content.addSubview(split)
        bar.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content
        NSLayoutConstraint.activate([
            // A fixed height: a bar without one stretches and squeezes the split to its minimum.
            bar.heightAnchor.constraint(equalToConstant: 26),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func buildOutline() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.indentationPerLevel = 12
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outline.menu = contextMenu
        outline.style = .sourceList
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(outlineScrolled), name: NSView.boundsDidChangeNotification,
            object: outlineScroll.contentView)
        outlineScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return outlineScroll
    }

    private func buildRight() -> NSView {
        headerLabel.font = .systemFont(ofSize: 12)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.maximumNumberOfLines = 3

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(tableScrolled), name: NSView.boundsDidChangeNotification,
            object: tableScroll.contentView)

        let list = NSStackView(views: [headerLabel, tableScroll])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        // The table takes the height the header leaves; without this it keeps a height of 0.
        list.distribution = .fill
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        headerLabel.setContentHuggingPriority(.required, for: .vertical)
        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        tableScroll.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(list)
        split.addArrangedSubview(buildDetail())
        return split
    }

    private func buildDetail() -> NSView {
        for (button, selector) in [
            (copyButton, #selector(copyClicked)), (pinButton, #selector(pinClicked)),
            (starButton, #selector(starClicked)), (deleteButton, #selector(deleteClicked)),
            (undoButton, #selector(undoClicked)), (exportButton, #selector(exportClicked)),
            (fetchButton, #selector(fetchClicked)), (notSecretButton, #selector(notSecretClicked)),
        ] {
            button.target = self
            button.action = selector
            button.bezelStyle = .rounded
        }
        let buttons = NSStackView(views: [
            copyButton, pinButton, starButton, deleteButton, undoButton, exportButton,
            fetchButton, notSecretButton,
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let contentScroll = Self.readOnlyScroll(contentView, monospaced: true)
        let infoScroll = Self.readOnlyScroll(infoView, monospaced: false)
        infoScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let stack = NSStackView(views: [buttons, contentScroll, infoScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        // The content takes the height the buttons and the info box leave.
        stack.distribution = .fill
        contentScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        buttons.setContentHuggingPriority(.required, for: .vertical)
        contentScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        for scroll in [contentScroll, infoScroll] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        showNoDetail()
        return stack
    }

    private static func readOnlyScroll(_ view: NSTextView, monospaced: Bool) -> NSScrollView {
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.font =
            monospaced
            ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        view.textColor = .labelColor
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        return scroll
    }

    // MARK: - Left side

    private func reloadEntityMenu() {
        do {
            entityChoices = try browser.entityChoices()
        } catch {
            Self.logger.error("Entities failed: \(String(describing: error), privacy: .public)")
            entityChoices = []
        }
        let format = HistoryFormat()
        entityMenu.removeAllItems()
        entityMenu.addItem(withTitle: "Alle Entitäten")
        for choice in entityChoices {
            entityMenu.addItem(withTitle: "\(format.entityTitle(choice.filter)) (\(choice.uses))")
        }
        if let current = entityFilter,
            let index = entityChoices.firstIndex(where: { $0.filter == current })
        {
            entityMenu.selectItem(at: index + 1)
        } else {
            entityFilter = nil
            entityMenu.selectItem(at: 0)
        }
    }

    /// Starts over with the first page of the current mode.
    private func reloadLeft() {
        timeline = DayTimeline()
        daysExhausted = false
        topicLimit = Self.topicPageSize
        dayNodes = []
        topicNodes = []
        isLoading = true
        outline.reloadData()
        isLoading = false
        switch mode {
        case .days: loadMoreDays()
        case .topics: reloadTopics()
        }
        if outline.selectedRow < 0 { selectScope(.all, header: "") }
        fillLeftIfNeeded()
    }

    private func loadMoreDays() {
        guard mode == .days, !daysExhausted, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try browser.sessions(
                limit: Self.sessionPageSize, after: timeline.last, entity: entityFilter)
            if page.count < Self.sessionPageSize { daysExhausted = true }
            let sectionsBefore = timeline.sections.count
            let lastCountBefore = timeline.sections.last?.sessions.count ?? 0
            timeline.append(page)
            // Insert instead of reloading, so selection, scroll position and collapsed days stay.
            if let node = dayNodes.last, sectionsBefore > 0 {
                let section = timeline.sections[sectionsBefore - 1]
                if section.sessions.count > lastCountBefore {
                    let start = node.sessions.count
                    node.section = section
                    node.sessions += section.sessions[lastCountBefore...].map(SessionNode.init)
                    outline.insertItems(
                        at: IndexSet(start..<node.sessions.count), inParent: node,
                        withAnimation: [])
                }
            }
            let added = timeline.sections[sectionsBefore...].map(DayNode.init)
            if !added.isEmpty {
                let start = dayNodes.count
                dayNodes += added
                outline.insertItems(
                    at: IndexSet(start..<dayNodes.count), inParent: nil, withAnimation: [])
                for node in added { outline.expandItem(node) }
            }
        } catch {
            daysExhausted = true
            Self.logger.error("Days failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func reloadTopics() {
        do {
            let known = Dictionary(uniqueKeysWithValues: topicNodes.map { ($0.summary.id, $0) })
            let topics = try browser.topics(limit: topicLimit, entity: entityFilter)
            topicNodes = topics.map { summary in
                guard let node = known[summary.id], node.summary == summary else {
                    return TopicNode(summary)
                }
                return node
            }
            outline.reloadData()
            for node in topicNodes where node.isExpanded { outline.expandItem(node) }
        } catch {
            Self.logger.error("Topics failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadMoreTopics() {
        guard mode == .topics, topicNodes.count >= topicLimit, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        topicLimit += Self.topicPageSize
        reloadTopics()
    }

    private func loadMoreLeft() {
        switch mode {
        case .days: loadMoreDays()
        case .topics: loadMoreTopics()
        }
    }

    /// A short list may not scroll at all, so nothing would ask for the next page.
    private func fillLeftIfNeeded() {
        var rounds = 0
        while rounds < 20, isNearEnd(outlineScroll), canLoadMoreLeft {
            let before = outline.numberOfRows
            loadMoreLeft()
            if outline.numberOfRows == before { break }
            rounds += 1
        }
    }

    private var canLoadMoreLeft: Bool {
        switch mode {
        case .days: !daysExhausted
        case .topics: topicNodes.count >= topicLimit
        }
    }

    private func isNearEnd(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        return scroll.contentView.bounds.maxY > document.frame.height - Self.nearEnd
    }

    @objc private func outlineScrolled() {
        if isNearEnd(outlineScroll) { loadMoreLeft() }
    }

    @objc private func modeChanged() {
        mode = Mode(rawValue: modeControl.selectedSegment) ?? .days
        selectScope(.all, header: "")
        reloadLeft()
    }

    @objc private func entityChanged() {
        let index = entityMenu.indexOfSelectedItem
        entityFilter = index > 0 ? entityChoices[index - 1].filter : nil
        selectScope(.all, header: "")
        reloadLeft()
    }

    private var selectedSessionID: Int64? {
        (outline.item(atRow: outline.selectedRow) as? SessionNode)?.summary.id
    }

    private func restoreSelection(sessionID: Int64?) {
        guard let sessionID else { return }
        for row in 0..<outline.numberOfRows {
            if (outline.item(atRow: row) as? SessionNode)?.summary.id == sessionID {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
    }

    // MARK: - Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: mode == .days ? dayNodes.count : topicNodes.count
        case let day as DayNode: day.sessions.count
        case let topic as TopicNode: sessions(of: topic).count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: mode == .days ? dayNodes[index] : topicNodes[index]
        case let day as DayNode: day.sessions[index]
        case let topic as TopicNode: sessions(of: topic)[index]
        default: fatalError("Session rows have no children")
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is DayNode || item is TopicNode
    }

    private func sessions(of topic: TopicNode) -> [SessionNode] {
        if let loaded = topic.sessions { return loaded }
        do {
            let kept = try browser.sessions(inTopic: topic.summary.id, entity: entityFilter)
            topic.sessions = kept.map(SessionNode.init)
        } catch {
            Self.logger.error(
                "Topic sessions failed: \(String(describing: error), privacy: .public)")
            topic.sessions = []
        }
        return topic.sessions ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is DayNode ? 26 : 42
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        let format = HistoryFormat()
        switch item {
        case let day as DayNode:
            let title = NSTextField(labelWithString: format.dayTitle(day.section.day))
            title.font = .boldSystemFont(ofSize: 13)
            return title
        case let session as SessionNode:
            return Self.twoLines(
                format.sessionTitle(session.summary), format.sessionSubtitle(session.summary))
        case let topic as TopicNode:
            return Self.twoLines(
                topic.summary.label, format.topicSubtitle(topic.summary), titleWeight: .semibold)
        default: return nil
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? TopicNode)?.isExpanded = true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? TopicNode)?.isExpanded = false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let format = HistoryFormat()
        switch outline.item(atRow: outline.selectedRow) {
        case let day as DayNode:
            let count = day.sessions.count
            // The last day may continue on pages that are not loaded yet.
            let isIncomplete = day === dayNodes.last && !daysExhausted
            let sessionCount =
                count == 1 && !isIncomplete
                ? "1 Session" : "\(count)\(isIncomplete ? "+" : "") Sessions"
            selectScope(
                .day(day.section.day),
                header: "\(format.dayTitle(day.section.day)) · \(sessionCount)")
        case let session as SessionNode:
            selectScope(.session(session.summary.id), header: sessionHeader(session.summary))
        case let topic as TopicNode:
            let words = topic.summary.keywords.joined(separator: ", ")
            selectScope(
                .topic(topic.summary.id),
                header: "\(topic.summary.label) · \(format.topicSubtitle(topic.summary))"
                    + (words.isEmpty ? "" : "\nBegriffe: \(words)"))
        default: selectScope(.all, header: "")
        }
    }

    // MARK: - Topic management

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard menu === outline.menu else { return }
        switch outline.item(atRow: outline.clickedRow) {
        case let topic as TopicNode:
            addMenuItem("Thema umbenennen …", #selector(renameTopic(_:)), topic, to: menu)
            addMenuItem(
                "Mit anderem Thema zusammenführen …", #selector(mergeTopic(_:)), topic, to: menu)
        case let session as SessionNode:
            addMenuItem(
                "In anderes Thema verschieben …", #selector(moveSession(_:)), session, to: menu)
            addMenuItem(
                "Eigenes Thema daraus machen", #selector(splitSession(_:)), session, to: menu)
        default: break
        }
    }

    private func addMenuItem(_ title: String, _ action: Selector, _ node: NSObject, to menu: NSMenu)
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = node
        menu.addItem(item)
    }

    @objc private func renameTopic(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TopicNode else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = node.summary.labelIsManual ? node.summary.label : ""
        field.placeholderString = node.summary.label
        guard
            confirm(
                "Thema umbenennen",
                "Ein leerer Name stellt die automatische Bezeichnung wieder her. Die Sessions des Themas bleiben danach zusammen.",
                accessory: field, button: "Umbenennen")
        else { return }
        applyTopicChange { try topics.rename(topic: node.summary.id, to: field.stringValue) }
    }

    @objc private func mergeTopic(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TopicNode,
            let target = chooseTopic(
                "Thema zusammenführen",
                "Alle Sessions von „\(node.summary.label)“ wandern in das gewählte Thema, das alte verschwindet.",
                excluding: [node.summary.id], button: "Zusammenführen")
        else { return }
        applyTopicChange { try topics.merge(topic: node.summary.id, into: target) }
    }

    @objc private func moveSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SessionNode else { return }
        let current = try? topics.topic(ofSession: node.summary.id)?.topicID
        guard
            let target = chooseTopic(
                "Session verschieben", "Die Session bleibt danach in diesem Thema.",
                excluding: current.map { [$0] } ?? [], button: "Verschieben")
        else { return }
        applyTopicChange { try topics.assign(sessionID: node.summary.id, toTopic: target) }
    }

    @objc private func splitSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SessionNode else { return }
        applyTopicChange { try topics.splitOff(sessionID: node.summary.id) != nil }
    }

    /// Runs a topic change and refreshes the outline; says so when nothing changed.
    private func applyTopicChange(_ change: () throws -> Bool) {
        do {
            let changed = try change()
            exportNote = changed ? "" : "Das Thema gibt es nicht mehr."
            reloadLeftKeepingSelection()
        } catch {
            Self.logger.error("Topic change failed: \(String(describing: error), privacy: .public)")
            exportNote = "Änderung konnte nicht gespeichert werden."
            reloadHeader()
        }
    }

    private func reloadLeftKeepingSelection() {
        let session = selectedSessionID
        reloadLeft()
        restoreSelection(sessionID: session)
        reloadHeader()
    }

    private func confirm(
        _ title: String, _ text: String, accessory: NSView?, button: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.accessoryView = accessory
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks which topic to use; nil if cancelled or there is none to choose.
    private func chooseTopic(
        _ title: String, _ text: String, excluding: [Int64], button: String
    ) -> Int64? {
        let choices: [TopicSummary]
        do {
            choices = try topics.topics(limit: 200).filter { !excluding.contains($0.id) }
        } catch {
            exportNote = "Themen konnten nicht geladen werden."
            reloadHeader()
            return nil
        }
        guard !choices.isEmpty else {
            exportNote = "Es gibt kein anderes Thema."
            reloadHeader()
            return nil
        }
        let format = HistoryFormat()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        popup.addItems(
            withTitles: choices.map { "\($0.label) – \(format.topicSubtitle($0))" })
        guard confirm(title, text, accessory: popup, button: button),
            choices.indices.contains(popup.indexOfSelectedItem)
        else { return nil }
        return choices[popup.indexOfSelectedItem].id
    }

    private func sessionHeader(_ session: SessionSummary) -> String {
        let format = HistoryFormat()
        var header = "\(format.dateTime(session.startedAt)) · \(session.explanation)"
        do {
            if let topic = try browser.topicInfo(ofSession: session.id) {
                header += "\nThema: \(topic.label) – \(topic.reason)"
                if topic.isLocked { header += " (von Hand zugeordnet)" }
            }
        } catch {
            Self.logger.error("Topic info failed: \(String(describing: error), privacy: .public)")
        }
        return header
    }

    // MARK: - Entries

    private func selectScope(_ newScope: HistoryScope, header: String) {
        scope = newScope
        baseHeader = header
        exportNote = ""
        reloadRows()
    }

    private var query: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reloadRows() {
        let format = HistoryFormat()
        entryCursor = nil
        entriesExhausted = true
        var note = ""
        defer { searchNote = note }
        do {
            if query.isEmpty, case .session(let id) = scope {
                let page = try browser.entries(inSession: id, limit: Self.entryPageSize)
                rows = page.map { HistoryRow(entry: $0, format: format) }
                entryCursor = page.last
                entriesExhausted = page.count < Self.entryPageSize
            } else {
                let hits = try search.search(
                    query, filter: scope.filter(limit: Self.searchLimit))
                rows = hits.map { HistoryRow(hit: $0, format: format) }
                if hits.count == Self.searchLimit {
                    note = "Zeigt die ersten \(Self.searchLimit) Treffer – Suche eingrenzen."
                }
            }
        } catch {
            Self.logger.error("Entries failed: \(String(describing: error), privacy: .public)")
            rows = []
        }
        headerLabel.stringValue = [baseHeader, exportNote, note].filter { !$0.isEmpty }.joined(
            separator: "\n")
        table.deselectAll(nil)
        table.reloadData()
        tableScroll.contentView.scroll(to: .zero)
        showNoDetail()
    }

    private func loadMoreEntries() {
        guard !entriesExhausted, !isLoading, query.isEmpty, case .session(let id) = scope else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try browser.entries(
                inSession: id, limit: Self.entryPageSize, after: entryCursor)
            let format = HistoryFormat()
            entriesExhausted = page.count < Self.entryPageSize
            guard let last = page.last else { return }
            entryCursor = last
            let selected = table.selectedRow
            rows += page.map { HistoryRow(entry: $0, format: format) }
            table.reloadData()
            if selected >= 0 { table.selectRowIndexes([selected], byExtendingSelection: false) }
        } catch {
            entriesExhausted = true
            Self.logger.error("More entries failed: \(String(describing: error), privacy: .public)")
        }
    }

    @objc private func tableScrolled() {
        if isNearEnd(tableScroll) { loadMoreEntries() }
    }

    func controlTextDidChange(_ notification: Notification) {
        reloadRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        Self.twoLines(rows[row].title, rows[row].subtitle)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = table.selectedRow
        guard rows.indices.contains(index) else {
            showNoDetail()
            return
        }
        showDetail(contentID: rows[index].contentID)
    }

    private static func twoLines(
        _ title: String, _ subtitle: String, titleWeight: NSFont.Weight = .regular
    ) -> NSView {
        let first = NSTextField(labelWithString: title)
        first.font = .systemFont(ofSize: 13, weight: titleWeight)
        first.lineBreakMode = .byTruncatingTail
        let second = NSTextField(labelWithString: subtitle)
        second.font = .systemFont(ofSize: 11)
        second.textColor = .secondaryLabelColor
        second.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [first, second])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        return stack
    }

    // MARK: - Detail

    private func showNoDetail() {
        detail = nil
        parkedSecret = nil
        contentView.string = rows.isEmpty ? "Keine Einträge." : "Eintrag auswählen."
        infoView.string = ""
        updateButtons()
    }

    private func showDetail(contentID: Int64) {
        lastDeletedID = nil
        secretNote = ""
        reloadHeader()
        do {
            guard let loaded = try browser.detail(contentID: contentID) else {
                showNoDetail()
                return
            }
            detail = loaded
            parkedSecret =
                loaded.kind == ContentKind.secret.rawValue
                ? try secrets.secret(forContentID: contentID) : nil
            contentView.string = loaded.text
            infoView.string = info(for: loaded).joined(separator: "\n")
        } catch {
            Self.logger.error("Detail failed: \(String(describing: error), privacy: .public)")
            showNoDetail()
            return
        }
        updateButtons()
    }

    private func info(for entry: EntryDetail) -> [String] {
        let format = HistoryFormat()
        var lines = ["\(entry.occurrenceCount)× kopiert"]
        if entry.kind == ContentKind.secret.rawValue {
            lines.append("Gesichertes Secret: der Wert liegt im Schlüsselbund, nicht hier.")
        }
        for occurrence in entry.occurrences {
            let place = [occurrence.appName, occurrence.windowTitle, occurrence.url]
                .compactMap { $0 }.joined(separator: " · ")
            lines.append(
                "• \(format.dateTime(occurrence.copiedAt))" + (place.isEmpty ? "" : " · \(place)"))
        }
        if entry.occurrenceCount > entry.occurrences.count {
            lines.append("• … und \(entry.occurrenceCount - entry.occurrences.count) ältere")
        }
        if !entry.entities.isEmpty {
            lines.append(
                "Erkannt: "
                    + entry.entities.map { "\(HistoryFormat.entityKindName($0.kind)) \($0.value)" }
                    .joined(separator: ", "))
        }
        if let score = entry.score {
            lines.append("")
            lines.append("Warum so wichtig:")
            lines += format.scoreLines(score).map { "  \($0)" }
        }
        return lines
    }

    private func updateButtons() {
        let isSecret = detail?.kind == ContentKind.secret.rawValue
        copyButton.isEnabled = detail != nil && !isSecret
        pinButton.isEnabled = detail != nil
        starButton.isEnabled = detail != nil
        deleteButton.isEnabled = detail != nil
        pinButton.title = detail?.isPinned == true ? "Lösen" : "Anheften"
        starButton.title = detail?.isStarred == true ? "Markierung entfernen" : "Markieren"
        undoButton.isHidden = lastDeletedID == nil
        let hasSecret = parkedSecret != nil && parkedSecret?.state != .lost
        fetchButton.isHidden = !hasSecret
        notSecretButton.isHidden = !hasSecret
        fetchButton.isEnabled = hasSecret && !isWorkingOnSecret
        notSecretButton.isEnabled = hasSecret && !isWorkingOnSecret
        exportButton.isEnabled = exportScope != nil
    }

    private var exportScope: ExportScope? {
        switch scope {
        case .all: nil
        case .day(let date): .day(date)
        case .session(let id): .session(id)
        case .topic(let id): .topic(id)
        }
    }

    /// Exports the selected day, session or topic into a folder the user picks.
    @objc private func exportClicked() {
        guard let exportScope else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Exportieren"
        panel.message = "Zielordner für den Markdown-Export wählen"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            MainActor.assumeIsolated { self?.export(exportScope, to: directory) }
        }
    }

    /// Builds and writes the document off the main thread; large exports would freeze the window.
    private func export(_ exportScope: ExportScope, to directory: URL) {
        guard !isExporting else { return }
        isExporting = true
        exportButton.isEnabled = false
        exportNote = "Export läuft …"
        reloadHeader()
        let exporter = exporter
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result<(MarkdownDocument, URL)?, Error> {
                guard let document = try exporter.export(exportScope) else { return nil }
                return (document, try MarkdownExporter.write(document, to: directory))
            }
            await self?.finishExport(result)
        }
    }

    private func finishExport(_ result: Result<(MarkdownDocument, URL)?, Error>) {
        isExporting = false
        exportButton.isEnabled = exportScope != nil
        switch result {
        case .success(nil):
            exportNote = "Nichts zu exportieren."
            reloadHeader()
        case .success(let (document, url)?):
            exportNote =
                "Exportiert: \(url.lastPathComponent) (\(document.entryCount) Einträge"
                + (document.withheldSecrets > 0
                    ? ", \(document.withheldSecrets) Secrets nicht exportiert" : "") + ")"
            reloadHeader()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let error):
            Self.logger.error("Export failed: \(String(describing: error), privacy: .public)")
            exportNote = "Export fehlgeschlagen: \(error.localizedDescription)"
            reloadHeader()
        }
    }

    private func reloadHeader() {
        headerLabel.stringValue = [baseHeader, exportNote, secretNote, searchNote].filter {
            !$0.isEmpty
        }
        .joined(separator: "\n")
    }

    /// Copies the secret behind the selected placeholder to the clipboard, fetching it from
    /// Bitwarden if it no longer sits in the Keychain.
    @objc private func fetchClicked() {
        guard let parked = parkedSecret, !isWorkingOnSecret else { return }
        runSecretAction(working: "Secret wird abgerufen …") { [bitwarden, copyWriter] in
            let value = try await bitwarden.retrieve(secretID: parked.id)
            copyWriter.copySecret(value)
            return "Secret in die Zwischenablage kopiert (wird nach 60 Sekunden entfernt)."
        }
    }

    /// Turns the placeholder back into a normal entry after the user confirms.
    @objc private func notSecretClicked() {
        guard let parked = parkedSecret, !isWorkingOnSecret else { return }
        let alert = NSAlert()
        alert.messageText = "Als „Kein Secret“ markieren?"
        alert.informativeText =
            "Der Text wird als normaler Eintrag im Verlauf gespeichert, auch im Suchindex, und künftig nicht mehr gesichert."
        alert.addButton(withTitle: "Markieren")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let contentID = detail?.contentID
        runSecretAction(working: "Wird zurückgestellt …") { [bitwarden] in
            try await bitwarden.markNotSecret(id: parked.id)
            return "Als normaler Eintrag gespeichert."
        } then: { [weak self] in
            // The placeholder text changed; reload what is shown.
            self?.reloadRows()
            if let contentID { self?.showDetail(contentID: contentID) }
        }
    }

    private func runSecretAction(
        working: String, _ action: @escaping @Sendable () async throws -> String,
        then reload: (@MainActor () -> Void)? = nil
    ) {
        isWorkingOnSecret = true
        secretNote = working
        reloadHeader()
        updateButtons()
        Task { [weak self] in
            let message: String
            do {
                message = try await action()
            } catch {
                Self.logger.error(
                    "Secret action failed: \(String(describing: error), privacy: .public)")
                message = Self.secretFailureText(error)
            }
            self?.isWorkingOnSecret = false
            reload?()
            self?.secretNote = message
            self?.reloadHeader()
            self?.updateButtons()
        }
    }

    private static func secretFailureText(_ error: Error) -> String {
        if let error = error as? BitwardenError {
            switch error {
            case .locked, .loggedOut:
                return "Bitwarden ist gesperrt: im Menü unter „Bitwarden“ entsperren."
            case .notInstalled: return "Bitwarden-CLI („bw“) ist nicht installiert."
            case .offline: return "Keine Verbindung zu Bitwarden."
            case .busy: return "Eine Übertragung läuft gerade, bitte gleich nochmal versuchen."
            default: return "Bitwarden hat nicht geantwortet."
            }
        }
        if error as? ParkingError != nil {
            return "Das Secret ist nicht mehr auffindbar."
        }
        return "Aktion fehlgeschlagen."
    }

    @objc private func copyClicked() {
        guard let detail else { return }
        copyWriter.copy(detail.text)
    }

    @objc private func pinClicked() {
        guard let detail else { return }
        let pinned = !detail.isPinned
        guard run({ try actions.setPinned(pinned, contentID: detail.contentID) }) else { return }
        refreshRow(isPinned: pinned, isStarred: detail.isStarred)
    }

    @objc private func starClicked() {
        guard let detail else { return }
        let starred = !detail.isStarred
        guard run({ try actions.setStarred(starred, contentID: detail.contentID) }) else { return }
        refreshRow(isPinned: detail.isPinned, isStarred: starred)
    }

    @objc private func deleteClicked() {
        guard let detail, run({ try actions.delete(contentID: detail.contentID) }) else { return }
        if let index = rows.firstIndex(where: { $0.contentID == detail.contentID }) {
            rows.remove(at: index)
            table.deselectAll(nil)
            table.removeRows(at: [index], withAnimation: [])
        }
        showNoDetail()
        lastDeletedID = detail.contentID
        updateButtons()
    }

    @objc private func undoClicked() {
        guard let id = lastDeletedID, run({ try actions.restore(contentID: id) }) else { return }
        lastDeletedID = nil
        reloadRows()
    }

    private func run(_ action: () throws -> Bool) -> Bool {
        do {
            return try action()
        } catch {
            Self.logger.error("Action failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Updates the selected row and the detail in place, so the list keeps its place.
    private func refreshRow(isPinned: Bool, isStarred: Bool) {
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        rows[index] = rows[index].with(isPinned: isPinned, isStarred: isStarred)
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
        showDetail(contentID: rows[index].contentID)
    }
}

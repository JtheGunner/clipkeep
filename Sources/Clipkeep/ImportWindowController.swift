import AppKit
import ClipkeepCore
import UniformTypeIdentifiers
import os

/// Stops a running import from another thread.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Imports a collected text document: choose the file, check how it is cut and what would
/// happen (preview), then import in the background with progress.
@MainActor
final class ImportWindowController: NSObject, NSWindowDelegate {
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "import")

    private let importer: TextImporter
    private let remover: ImportRemover
    private let window: NSWindow
    private let fileLabel = NSTextField(labelWithString: "")
    private let modeMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let sampleView = NSTextView()
    private let progress = NSProgressIndicator()
    private let importButton = NSButton(title: "Importieren", target: nil, action: nil)
    private let closeButton = NSButton(title: "Schliessen", target: nil, action: nil)

    private var text = ""
    private var fileName = ""
    private var fileDate = Date()
    private var previewGeneration = 0
    private var previewCancel: CancelFlag?
    private var cancelFlag: CancelFlag?
    private var isImporting = false

    private static let modes: [(SplitMode, String)] = [
        (.automatic, "Automatisch"), (.separatorLines, "Trennlinien (---, ===)"),
        (.blankLines, "Leerzeilen"), (.everyLine, "Jede Zeile"),
    ]

    init(remover: ImportRemover, importer: TextImporter) {
        self.importer = importer
        self.remover = remover
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.Window.importer),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    // MARK: - Starting

    /// Asks for a file, then shows the preview window.
    func start() {
        guard !isImporting else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text, .utf8PlainText]
        panel.message = "Textdatei mit gesammelten Einträgen wählen"
        panel.prompt = "Öffnen"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    // MARK: - Removing an import

    /// Lists the imported files and deletes the chosen one after a confirmation. The result
    /// offers an undo while the dialog is still on screen.
    func removeImports() {
        let imports: [ImportedSource]
        do {
            imports = try remover.imports()
        } catch {
            Self.logger.error(
                "Listing imports failed: \(String(describing: error), privacy: .public)")
            showMessage("Importe konnten nicht geladen werden.")
            return
        }
        guard !imports.isEmpty else {
            showMessage("Es gibt keine importierten Einträge.")
            return
        }
        let format = DateFormatter()
        format.dateStyle = .medium
        format.timeStyle = .none
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        for item in imports {
            let count = item.entryCount == 1 ? "1 Eintrag" : "\(item.entryCount) Einträge"
            choice.addItem(
                withTitle: "\(item.source) – \(count), \(format.string(from: item.lastEntryAt))")
        }
        let alert = NSAlert()
        alert.messageText = "Import löschen"
        alert.informativeText =
            "Löscht die Einträge, die nur aus diesem Import stammen. Einträge, die es schon vorher gab, bleiben."
        alert.accessoryView = choice
        alert.addButton(withTitle: "Löschen …")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
            imports.indices.contains(choice.indexOfSelectedItem)
        else { return }
        confirmRemoval(of: imports[choice.indexOfSelectedItem])
    }

    private func confirmRemoval(of item: ImportedSource) {
        let count = item.entryCount == 1 ? "1 Eintrag" : "\(item.entryCount) Einträge"
        let confirm = NSAlert()
        confirm.messageText = "\(count) aus „\(item.source)“ löschen?"
        confirm.informativeText = "Gelöschte Einträge werden nach 30 Tagen endgültig entfernt."
        confirm.addButton(withTitle: "Löschen")
        confirm.addButton(withTitle: "Abbrechen")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            let removed = try remover.remove(source: item.source)
            let done = NSAlert()
            done.messageText =
                removed.count == 1 ? "1 Eintrag gelöscht" : "\(removed.count) Einträge gelöscht"
            done.addButton(withTitle: "OK")
            if !removed.isEmpty { done.addButton(withTitle: "Rückgängig") }
            if done.runModal() == .alertSecondButtonReturn { restore(removed) }
        } catch {
            Self.logger.error(
                "Removing an import failed: \(String(describing: error), privacy: .public)")
            showMessage("Import konnte nicht gelöscht werden.")
        }
    }

    private func restore(_ ids: [Int64]) {
        do {
            try remover.restore(ids)
            showMessage(
                ids.count == 1
                    ? "1 Eintrag wiederhergestellt" : "\(ids.count) Einträge wiederhergestellt")
        } catch {
            Self.logger.error(
                "Restoring an import failed: \(String(describing: error), privacy: .public)")
            showMessage("Einträge konnten nicht wiederhergestellt werden.")
        }
    }

    private func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func load(_ url: URL) {
        fileName = url.lastPathComponent
        fileDate =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
        fileLabel.stringValue = fileName
        modeMenu.selectItem(at: 0)
        progress.doubleValue = 0
        closeButton.title = "Schliessen"
        importButton.isEnabled = false
        summaryLabel.stringValue = "Datei wird gelesen …"
        sampleView.string = ""
        window.makeKeyAndOrderFront(nil)
        // Reading and decoding a big file takes a moment; the window stays responsive.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try TextImporter.read(url) }
            await self?.didRead(result)
        }
    }

    private func didRead(_ result: Result<String, Error>) {
        switch result {
        case .success(let loaded):
            text = loaded
            refreshPreview()
        case .failure(let error):
            Self.logger.error("Reading failed: \(String(describing: error), privacy: .public)")
            summaryLabel.stringValue =
                "Datei konnte nicht gelesen werden: keine Textdatei oder grösser als 200 MB."
        }
    }

    /// The text can hold years of private notes; it is not kept longer than needed.
    private func forgetText() {
        text = ""
        previewCancel?.cancel()
    }

    // MARK: - Building

    private func build() {
        window.title = "Textdatei importieren"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = Metrics.Window.importerMin

        fileLabel.font = Typography.sectionTitle
        for (_, title) in Self.modes { modeMenu.addItem(withTitle: title) }
        modeMenu.target = self
        modeMenu.action = #selector(modeChanged)
        let modeRow = NSStackView(views: [
            NSTextField(labelWithString: "Einträge trennen an:"), modeMenu,
        ])
        modeRow.spacing = Metrics.Space.s

        summaryLabel.font = Typography.detail
        summaryLabel.maximumNumberOfLines = 6

        sampleView.isEditable = false
        sampleView.font = Typography.monoSmall
        sampleView.textColor = .labelColor
        sampleView.drawsBackground = false
        sampleView.textContainerInset = Metrics.textInset
        sampleView.isVerticallyResizable = true
        sampleView.autoresizingMask = [.width]
        sampleView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = sampleView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar

        importButton.target = self
        importButton.action = #selector(importClicked)
        importButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        let buttons = NSStackView(views: [closeButton, importButton])
        buttons.spacing = Metrics.Space.s

        let stack = NSStackView(views: [
            fileLabel, modeRow, summaryLabel, scroll, progress, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.Space.s
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.Space.l, left: Metrics.Space.l, bottom: Metrics.Space.l,
            right: Metrics.Space.l)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        for view in [scroll, progress, summaryLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -2 * Metrics.Space.l
            ).isActive = true
        }
        buttons.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -Metrics.Space.l
        ).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.Pane.sampleMinHeight)
            .isActive = true
    }

    // MARK: - Preview

    private var selectedMode: SplitMode {
        Self.modes[max(modeMenu.indexOfSelectedItem, 0)].0
    }

    @objc private func modeChanged() {
        refreshPreview()
    }

    private func refreshPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        let importer = importer
        let text = text
        let mode = selectedMode
        importButton.isEnabled = false
        summaryLabel.stringValue = "Vorschau wird berechnet …"
        sampleView.string = ""
        previewCancel?.cancel()
        let cancel = CancelFlag()
        previewCancel = cancel
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try importer.preview(text: text, mode: mode, isCancelled: { cancel.isCancelled })
            }
            await self?.showPreview(result, generation: generation)
        }
    }

    private func showPreview(_ result: Result<ImportPreview, Error>, generation: Int) {
        // A newer preview was asked for while this one was computed.
        guard generation == previewGeneration else { return }
        if case .failure(let error) = result, error is CancellationError { return }
        switch result {
        case .success(let preview):
            let importable =
                preview.entryCount - preview.secretCount - preview.alreadyStoredCount
                - preview.tooShortCount - preview.tooLongCount
            var lines = ["\(preview.entryCount) Einträge erkannt, davon neu: \(max(importable, 0))"]
            lines.append(
                preview.headingCount > 0
                    ? "\(preview.headingCount) Datumsüberschriften erkannt: Einträge erhalten das jeweilige Datum"
                    : "Keine Datumsüberschriften: jeder Block wird eine eigene Session")
            if preview.alreadyStoredCount > 0 {
                lines.append("\(preview.alreadyStoredCount) schon vorhanden (werden übersprungen)")
            }
            if preview.secretCount > 0 {
                lines.append(
                    "\(preview.secretCount) mögliche Secrets: werden gesichert, nicht importiert")
            }
            if preview.warnsAboutSecretBlocks {
                let percent = Int((preview.secretShare * 100).rounded())
                lines.append(
                    "⚠︎ Die \(preview.secretCount) Secret-Einträge machen \(percent) % des Textes aus und fallen komplett weg. Ein anderer Trennmodus (z. B. Leerzeilen) schneidet kleinere Blöcke."
                )
            }
            let skipped = preview.tooShortCount + preview.tooLongCount
            if skipped > 0 { lines.append("\(skipped) zu kurz oder zu lang (werden übersprungen)") }
            summaryLabel.stringValue = lines.joined(separator: "\n")
            sampleView.string = preview.samples.joined(separator: "\n──────\n")
            importButton.isEnabled = max(importable, 0) + preview.secretCount > 0
        case .failure(let error):
            Self.logger.error("Preview failed: \(String(describing: error), privacy: .public)")
            summaryLabel.stringValue = "Vorschau fehlgeschlagen."
        }
    }

    // MARK: - Importing

    @objc private func importClicked() {
        guard !isImporting else { return }
        isImporting = true
        importButton.isEnabled = false
        modeMenu.isEnabled = false
        closeButton.title = "Abbrechen"
        summaryLabel.stringValue = "Import läuft …"
        progress.doubleValue = 0
        let flag = CancelFlag()
        cancelFlag = flag
        let importer = importer
        let text = text
        let mode = selectedMode
        let source = fileName
        let date = fileDate
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.update(done, of: total) }
        }
        Task.detached(priority: .utility) { [weak self] in
            let result = Result {
                try importer.run(
                    text: text, mode: mode, source: source, endingAt: date,
                    progress: report,
                    isCancelled: { flag.isCancelled })
            }
            await self?.finish(result)
        }
    }

    private func update(_ done: Int, of total: Int) {
        guard isImporting else { return }
        progress.doubleValue = total > 0 ? Double(done) / Double(total) : 1
        summaryLabel.stringValue = "Import läuft … \(done) von \(total)"
    }

    private func finish(_ result: Result<ImportReport, Error>) {
        isImporting = false
        cancelFlag = nil
        forgetText()
        modeMenu.isEnabled = true
        closeButton.title = "Schliessen"
        switch result {
        case .success(let report):
            progress.doubleValue = 1
            var lines = [
                report.wasCancelled ? "Abgebrochen." : "Fertig.",
                "\(report.imported) importiert, \(report.duplicates) schon vorhanden",
            ]
            if report.secrets > 0 {
                lines.append("\(report.secrets) Secrets gesichert, nicht importiert")
            }
            if report.secretsFailed > 0 {
                lines.append(
                    "⚠︎ \(report.secretsFailed) Secrets konnten nicht gesichert werden und wurden verworfen"
                )
            }
            if report.skipped > 0 { lines.append("\(report.skipped) übersprungen") }
            summaryLabel.stringValue = lines.joined(separator: "\n")
            sampleView.string = ""
        case .failure(let error):
            Self.logger.error("Import failed: \(String(describing: error), privacy: .public)")
            summaryLabel.stringValue =
                "Import fehlgeschlagen. Bereits importierte Einträge bleiben erhalten."
        }
    }

    @objc private func closeClicked() {
        if isImporting {
            cancelFlag?.cancel()
        } else {
            forgetText()
            window.orderOut(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing during an import cancels it; the window stays until it has stopped.
        if isImporting {
            cancelFlag?.cancel()
            return false
        }
        forgetText()
        return true
    }
}

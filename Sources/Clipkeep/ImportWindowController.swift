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

    init(importer: TextImporter) {
        self.importer = importer
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
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
        window.minSize = NSSize(width: 520, height: 400)

        fileLabel.font = .boldSystemFont(ofSize: 13)
        for (_, title) in Self.modes { modeMenu.addItem(withTitle: title) }
        modeMenu.target = self
        modeMenu.action = #selector(modeChanged)
        let modeRow = NSStackView(views: [
            NSTextField(labelWithString: "Einträge trennen an:"), modeMenu,
        ])
        modeRow.spacing = 8

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.maximumNumberOfLines = 6

        sampleView.isEditable = false
        sampleView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sampleView.textColor = .labelColor
        sampleView.drawsBackground = false
        sampleView.textContainerInset = NSSize(width: 4, height: 6)
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
        buttons.spacing = 8

        let stack = NSStackView(views: [
            fileLabel, modeRow, summaryLabel, scroll, progress, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        for view in [scroll, progress, summaryLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16).isActive =
            true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
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

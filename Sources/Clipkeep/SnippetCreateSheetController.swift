import AppKit
import ClipkeepCore
import os

/// The sheet of the snippet explorer for adding a snippet by hand: text, language and comment.
/// The language follows the filter's guess while the user types, until they pick one.
@MainActor
final class SnippetCreateSheetController: NSObject, NSTextViewDelegate {
    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "snippets")

    private static let languages: [(SnippetLanguage, String)] = [
        (.shell, "Shell"), (.sql, "SQL"), (.yaml, "YAML"),
    ]

    private let creator: SnippetCreator
    private let onFinished: (SnippetCreateOutcome?) -> Void
    private let sheet: NSWindow
    private let textView = NSTextView()
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commentField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    /// The syntax check of the text as typed. Informational only: it never blocks saving.
    private let checkLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Speichern", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    private var languageChosenByUser = false
    private weak var parent: NSWindow?

    /// `onFinished` is called once after the sheet closed: with the outcome when a snippet was
    /// created or joined, with nil when the user cancelled.
    init(creator: SnippetCreator, onFinished: @escaping (SnippetCreateOutcome?) -> Void) {
        self.creator = creator
        self.onFinished = onFinished
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(on parent: NSWindow) {
        self.parent = parent
        parent.beginSheet(sheet)
        sheet.makeFirstResponder(textView)
    }

    private func build() {
        sheet.title = "Snippet hinzufügen"

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Typography.mono
        textView.textContainerInset = Metrics.textInset
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.setAccessibilityLabel("Text")
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        for (_, title) in Self.languages { languagePopup.addItem(withTitle: title) }
        languagePopup.target = self
        languagePopup.action = #selector(languagePicked)
        languagePopup.setAccessibilityLabel("Sprache")
        let languageRow = NSStackView(views: [
            Self.label("Sprache"), languagePopup,
        ])
        languageRow.orientation = .horizontal
        languageRow.spacing = Metrics.Space.s

        checkLabel.font = Typography.caption
        checkLabel.textColor = .secondaryLabelColor
        checkLabel.isHidden = true

        commentField.placeholderString = "Kommentar hinzufügen"
        commentField.setAccessibilityLabel("Kommentar")

        errorLabel.font = Typography.caption
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        saveButton.target = self
        saveButton.action = #selector(save)
        // Plain Return belongs to the multiline text; the shortcut is Command-Return.
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.Space.s

        let content = NSStackView(views: [
            Self.label("Text"), textScroll, checkLabel, languageRow, Self.label("Kommentar"),
            commentField, errorLabel, buttons,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Metrics.Space.s
        content.edgeInsets = NSEdgeInsets(
            top: Metrics.Space.l, left: Metrics.Space.l, bottom: Metrics.Space.l,
            right: Metrics.Space.l)
        for view in [textScroll, checkLabel, commentField, errorLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: content.widthAnchor, constant: -2 * Metrics.Space.l
            ).isActive = true
        }
        sheet.contentView = content
        applyGuessedLanguage()
        updateSyntaxCheck()
    }

    private static func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = Typography.caption
        label.textColor = .secondaryLabelColor
        return label
    }

    func textDidChange(_ notification: Notification) {
        errorLabel.isHidden = true
        if !languageChosenByUser { applyGuessedLanguage() }
        updateSyntaxCheck()
    }

    private var selectedLanguage: SnippetLanguage {
        Self.languages[max(0, languagePopup.indexOfSelectedItem)].0
    }

    /// Shows the check result for the current text and language; nothing when it was not checked.
    private func updateSyntaxCheck() {
        let status = SnippetValidator.check(textView.string, language: selectedLanguage).statusText
        checkLabel.stringValue = status ?? ""
        checkLabel.isHidden = status == nil
    }

    private func applyGuessedLanguage() {
        let guess = creator.guessLanguage(textView.string)
        guard let index = Self.languages.firstIndex(where: { $0.0 == guess }) else { return }
        languagePopup.selectItem(at: index)
    }

    @objc private func languagePicked() {
        languageChosenByUser = true
        updateSyntaxCheck()
    }

    @objc private func cancel() {
        close()
        onFinished(nil)
    }

    @objc private func save() {
        let language = selectedLanguage
        let outcome: SnippetCreateOutcome
        do {
            outcome = try creator.create(
                text: textView.string, language: language, comment: commentField.stringValue)
        } catch {
            Self.logger.error(
                "Creating a snippet failed: \(String(describing: error), privacy: .public)")
            show(error: "Das Snippet konnte nicht gespeichert werden.")
            return
        }
        switch outcome {
        case .empty: show(error: "Der Text ist leer.")
        case .tooLarge: show(error: "Der Text ist zu gross für ein Snippet.")
        case .residualSecret:
            show(error: "Der Text enthält ein Geheimnis, das nicht entfernt werden konnte.")
        case .commentResidualSecret:
            show(error: "Der Kommentar enthält ein Geheimnis, das nicht entfernt werden konnte.")
        case .created, .joined:
            close()
            onFinished(outcome)
        }
    }

    private func show(error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
    }

    private func close() {
        parent?.endSheet(sheet)
        sheet.orderOut(nil)
    }
}

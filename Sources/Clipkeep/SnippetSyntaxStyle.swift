import AppKit
import ClipkeepCore

/// Builds the coloured text of the explorer's detail view. It only styles: the characters of the
/// result equal `text` exactly, so what is shown is what gets copied.
enum SnippetSyntaxStyle {
    static func attributedString(for text: String, language: SnippetLanguage) -> NSAttributedString
    {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: Typography.mono, .foregroundColor: NSColor.labelColor])
        let length = (text as NSString).length
        // Text over the highlighter's length limit has no tokens and stays in the plain colour.
        result.beginEditing()
        for token in SnippetHighlighter.tokens(in: text, language: language)
        where NSMaxRange(token.range) <= length {
            result.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        result.endEditing()
        return result
    }

    static func color(for kind: SnippetTokenKind) -> NSColor {
        switch kind {
        case .keyword: SyntaxColors.keyword
        case .string: SyntaxColors.string
        case .number: SyntaxColors.number
        case .comment: SyntaxColors.comment
        case .op: SyntaxColors.op
        case .variable: SyntaxColors.variable
        case .key: SyntaxColors.key
        case .punctuation: SyntaxColors.punctuation
        }
    }
}

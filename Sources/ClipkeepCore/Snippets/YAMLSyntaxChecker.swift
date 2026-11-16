/// The YAML part of `SnippetValidator`: tabs used for indentation, inconsistent indentation, a
/// line without `:` inside a block mapping, unbalanced flow brackets and unterminated quoted
/// scalars. Block scalar bodies are skipped. Explicit keys, nested inline sequences, multi-line
/// plain scalars and other rarely used forms are `notChecked`.
struct YAMLSyntaxChecker {
    private enum LevelKind { case mapping, sequence, scalar }

    /// One open block collection: the column its entries start at and what they are.
    private struct Level {
        let indent: Int
        let kind: LevelKind
    }

    private enum Value {
        /// Nothing but anchors, tags or a comment: the content follows on the next lines.
        case empty
        case blockScalar
        case scalar
        /// A quoted scalar or flow collection that continues on the next line.
        case open
    }

    private struct Shape {
        var isKey = false
        var value: Value
    }

    private let bytes: [UInt8]
    private var levels: [Level] = []
    private var flow: [UInt8] = []
    private var quote: UInt8?
    /// The previous content line ended in `key:` or `-` with nothing after it.
    private var expectsChild = false
    /// The indentation of the line that started the block scalar being skipped.
    private var blockScalarParent: Int?
    private var lineNumber = 0
    private var sawContent = false

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func run() throws(SyntaxProblem) -> SnippetCheck {
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count && bytes[lineEnd] != ASCII.lineFeed { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > lineStart && bytes[contentEnd - 1] == ASCII.carriageReturn {
                contentEnd -= 1
            }
            lineNumber += 1
            try processLine(from: lineStart, to: contentEnd)
            lineStart = lineEnd + 1
        }
        if let quote {
            throw .invalid(
                "Anführungszeichen \(Character(Unicode.Scalar(quote))) nicht geschlossen")
        }
        if let open = flow.last {
            throw .invalid("Klammer \(Character(Unicode.Scalar(open))) nicht geschlossen")
        }
        return sawContent ? .valid : .notChecked
    }

    private func onLine(_ message: String) -> SyntaxProblem {
        .invalid("\(message) (Zeile \(lineNumber))")
    }

    // MARK: - Lines

    private mutating func processLine(from start: Int, to end: Int) throws(SyntaxProblem) {
        if quote != nil || !flow.isEmpty {
            guard let after = try scanInline(from: start, to: end) else { return }
            try requireLineEnd(from: after, to: end)
            expectsChild = false
            return
        }
        var contentStart = start
        while contentStart < end && bytes[contentStart] == ASCII.space { contentStart += 1 }
        let indent = contentStart - start
        var firstVisible = contentStart
        while firstVisible < end && ASCII.isBlank(bytes[firstVisible]) { firstVisible += 1 }
        let isBlankOrComment = firstVisible == end || bytes[firstVisible] == ASCII.hash

        if let parent = blockScalarParent {
            if firstVisible == end || indent > parent { return }
            // A tab right after the indentation of a block scalar body is not modelled.
            if bytes[contentStart] == ASCII.tab { throw .notChecked }
            blockScalarParent = nil
        }
        if isBlankOrComment { return }
        if bytes[contentStart] == ASCII.tab { throw onLine("Tabulator in der Einrückung") }
        sawContent = true
        if indent == 0
            && (startsMarker("---", at: start, end: end)
                || startsMarker("...", at: start, end: end))
        {
            levels.removeAll()
            expectsChild = false
            let rest = skipBlanks(from: start + 3, to: end)
            // `--- |` or `--- value` put content on the marker line.
            if rest < end && bytes[rest] != ASCII.hash { throw .notChecked }
            return
        }
        if indent == 0 && bytes[start] == ASCII.percent { return }
        try processContent(indent: indent, from: contentStart, to: end)
    }

    private func startsMarker(_ marker: String, at start: Int, end: Int) -> Bool {
        let markerBytes = Array(marker.utf8)
        guard end - start >= markerBytes.count,
            bytes[start..<(start + markerBytes.count)].elementsEqual(markerBytes)
        else { return false }
        let next = start + markerBytes.count
        return next == end || ASCII.isBlank(bytes[next])
    }

    private func skipBlanks(from start: Int, to end: Int) -> Int {
        var position = start
        while position < end && ASCII.isBlank(bytes[position]) { position += 1 }
        return position
    }

    private func isSequenceDash(at position: Int, end: Int) -> Bool {
        guard position < end, bytes[position] == ASCII.dash else { return false }
        return position + 1 == end || ASCII.isBlank(bytes[position + 1])
    }

    private mutating func processContent(indent: Int, from start: Int, to end: Int)
        throws(SyntaxProblem)
    {
        var column = start
        let isSequenceEntry = isSequenceDash(at: column, end: end)
        if isSequenceEntry {
            column += 1
            while column < end && bytes[column] == ASCII.space { column += 1 }
            if column < end && bytes[column] == ASCII.tab { throw .notChecked }
            // `- - x` nests sequences on one line.
            if isSequenceDash(at: column, end: end) { throw .notChecked }
        }
        let innerIndent = indent + (column - start)
        let shape = try scanNode(from: column, to: end, allowsKey: true)
        try place(
            indent: indent, isSequenceEntry: isSequenceEntry, innerIndent: innerIndent, shape: shape
        )
        if shape.value == .blockScalar { blockScalarParent = indent }
        expectsChild = shape.value == .empty && (shape.isKey || isSequenceEntry)
    }

    /// Checks the line's indentation against the open block collections and updates them.
    private mutating func place(indent: Int, isSequenceEntry: Bool, innerIndent: Int, shape: Shape)
        throws(SyntaxProblem)
    {
        var didDedent = false
        while let top = levels.last, top.indent > indent {
            levels.removeLast()
            didDedent = true
        }
        if let top = levels.last, top.indent == indent {
            if top.kind == .mapping && !isSequenceEntry && !shape.isKey && shape.value == .scalar {
                throw onLine("Zeile ohne „:“ in einer Zuordnung")
            }
        } else {
            if didDedent {
                // Dedenting below every open level happens in fragments cut out of a larger file.
                guard !levels.isEmpty else { throw .notChecked }
                throw onLine("Einrückung uneinheitlich")
            }
            if !levels.isEmpty && !expectsChild {
                // A deeper plain line continues a multi-line plain scalar, which is not modelled.
                guard shape.isKey || isSequenceEntry else { throw .notChecked }
                throw onLine("Einrückung uneinheitlich")
            }
            let kind: LevelKind = isSequenceEntry ? .sequence : shape.isKey ? .mapping : .scalar
            levels.append(Level(indent: indent, kind: kind))
        }
        if isSequenceEntry && shape.isKey {
            levels.append(Level(indent: innerIndent, kind: .mapping))
        }
    }

    // MARK: - Nodes

    /// Reads the node at `start`: optionally a key and its value, or a value alone. Recurses at
    /// most once, for the value after a key.
    private mutating func scanNode(from start: Int, to end: Int, allowsKey: Bool)
        throws(SyntaxProblem) -> Shape
    {
        let position = skipProperties(from: start, to: end)
        guard position < end, bytes[position] != ASCII.hash else { return Shape(value: .empty) }
        let byte = bytes[position]
        let next = bytes.byte(at: position + 1)
        let isIndicatorAlone = position + 1 == end || next.map(ASCII.isBlank) == true
        if byte == ASCII.pipe || byte == ASCII.greater {
            try validateBlockScalarHeader(from: position + 1, to: end)
            return Shape(value: .blockScalar)
        }
        if (byte == ASCII.question || byte == ASCII.colon) && isIndicatorAlone { throw .notChecked }
        if byte == ASCII.dash && isIndicatorAlone { throw .notChecked }
        if byte == ASCII.percent || byte == ASCII.at || byte == ASCII.backtick { throw .notChecked }

        let afterNode: Int
        if byte == ASCII.doubleQuote || byte == ASCII.singleQuote {
            quote = byte
            guard let after = try scanInline(from: position + 1, to: end) else {
                return Shape(value: .open)
            }
            afterNode = after
        } else if byte == ASCII.openBracket || byte == ASCII.openBrace {
            flow.append(byte)
            guard let after = try scanInline(from: position + 1, to: end) else {
                return Shape(value: .open)
            }
            afterNode = after
        } else {
            guard let separator = plainKeySeparator(from: position, to: end) else {
                return Shape(value: .scalar)
            }
            // `a: b: c` is not modelled.
            guard allowsKey else { throw .notChecked }
            let value = try scanNode(from: separator + 1, to: end, allowsKey: false).value
            return Shape(isKey: true, value: value)
        }
        let rest = skipBlanks(from: afterNode, to: end)
        if rest == end || bytes[rest] == ASCII.hash { return Shape(value: .scalar) }
        if bytes[rest] == ASCII.colon && (rest + 1 == end || ASCII.isBlank(bytes[rest + 1])) {
            guard allowsKey else { throw .notChecked }
            let value = try scanNode(from: rest + 1, to: end, allowsKey: false).value
            return Shape(isKey: true, value: value)
        }
        throw .notChecked
    }

    /// Skips blanks, anchors (`&a`) and tags (`!!str`) before a node.
    private func skipProperties(from start: Int, to end: Int) -> Int {
        var position = skipBlanks(from: start, to: end)
        while position < end
            && (bytes[position] == ASCII.ampersand || bytes[position] == ASCII.exclamation)
        {
            while position < end && !ASCII.isBlank(bytes[position]) { position += 1 }
            position = skipBlanks(from: position, to: end)
        }
        return position
    }

    /// The `:` that ends a plain key, or nil when the plain scalar is no key.
    private func plainKeySeparator(from start: Int, to end: Int) -> Int? {
        var position = start
        while position < end {
            let byte = bytes[position]
            if byte == ASCII.colon && (position + 1 == end || ASCII.isBlank(bytes[position + 1])) {
                return position
            }
            if byte == ASCII.hash && position > start && ASCII.isBlank(bytes[position - 1]) {
                return nil
            }
            position += 1
        }
        return nil
    }

    /// `|`, `>`, `|-`, `>+2` and the like, followed by nothing but an optional comment.
    private func validateBlockScalarHeader(from start: Int, to end: Int) throws(SyntaxProblem) {
        var position = start
        while position < end && position - start < 2
            && (bytes[position] == ASCII.plus || bytes[position] == ASCII.dash
                || ASCII.isDigit(bytes[position]))
        {
            position += 1
        }
        guard position == end || ASCII.isBlank(bytes[position]) else { throw .notChecked }
        let rest = skipBlanks(from: position, to: end)
        guard rest == end || bytes[rest] == ASCII.hash else { throw .notChecked }
    }

    /// After a multi-line quoted scalar or flow collection closes, only a comment may follow.
    private func requireLineEnd(from start: Int, to end: Int) throws(SyntaxProblem) {
        let rest = skipBlanks(from: start, to: end)
        guard rest == end || bytes[rest] == ASCII.hash else { throw .notChecked }
    }

    // MARK: - Quoted scalars and flow collections

    /// Continues the open quoted scalar or flow collection. Returns the position after it closes,
    /// or nil when it is still open at the end of the line.
    private mutating func scanInline(from start: Int, to end: Int) throws(SyntaxProblem) -> Int? {
        var position = start
        while position < end {
            let byte = bytes[position]
            if let open = quote {
                if open == ASCII.doubleQuote && byte == ASCII.backslash {
                    position += 2
                    continue
                }
                if byte == open {
                    if open == ASCII.singleQuote
                        && bytes.byte(at: position + 1) == ASCII.singleQuote
                        && position + 1 < end
                    {
                        position += 2
                        continue
                    }
                    quote = nil
                    position += 1
                    if flow.isEmpty { return position }
                    continue
                }
                position += 1
                continue
            }
            let previous = position > 0 ? bytes[position - 1] : ASCII.space
            switch byte {
            case ASCII.openBracket, ASCII.openBrace: flow.append(byte)
            case ASCII.closeBracket, ASCII.closeBrace:
                guard let open = flow.popLast() else { throw .notChecked }
                let matches =
                    (open == ASCII.openBracket && byte == ASCII.closeBracket)
                    || (open == ASCII.openBrace && byte == ASCII.closeBrace)
                guard matches else {
                    throw onLine(
                        "Klammer \(Character(Unicode.Scalar(byte))) passt nicht zu \(Character(Unicode.Scalar(open)))"
                    )
                }
                if flow.isEmpty { return position + 1 }
            case ASCII.doubleQuote, ASCII.singleQuote:
                // A quote only starts a scalar at the start of a flow entry; `[don't]` is plain.
                if Self.startsFlowEntry(previous) { quote = byte }
            case ASCII.hash:
                if ASCII.isWhitespace(previous) { return nil }
            default: break
            }
            position += 1
        }
        return nil
    }

    private static func startsFlowEntry(_ previous: UInt8) -> Bool {
        ASCII.isWhitespace(previous) || previous == ASCII.openBracket
            || previous == ASCII.openBrace || previous == ASCII.comma || previous == ASCII.colon
    }
}

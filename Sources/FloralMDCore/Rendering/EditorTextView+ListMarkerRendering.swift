// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit

/// List-item marker styling: maps a list item's leading whitespace to a nesting
/// depth, indents the content by one marker "slot" per level (Apple Notes
/// style), and positions the raw/rendered marker so the text column stays put
/// whether or not the caret is inside the item. Extracted from the `styleBlock`
/// switch in EditorTextView+Rendering.
extension EditorTextView {

    /// A marker-only ordered item (`1.` / `1)`) is valid CommonMark, so
    /// swift-markdown reports it as a list before the user has typed the space
    /// that normally signals intent. While that marker is actively being
    /// edited, keep ordinary paragraph geometry; `1. ` then enters the final
    /// list layout once, instead of jumping right on `.` and left on space.
    func isBareOrderedListMarker(_ markdown: String, range: NSRange) -> Bool {
        guard range.upperBound <= (markdown as NSString).length else { return false }
        let source = (markdown as NSString).substring(with: range)
            .drop(while: { $0 == " " || $0 == "\t" })
        let digits = source.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return false }
        let suffix = source.dropFirst(digits.count)
        return suffix == "." || suffix == ")"
    }

    /// Styles the `.listItem` content for one span. The caller has already
    /// bounds-checked `span.fullRange` against `result`.
    func styleListItemSpan(_ result: NSMutableAttributedString,
                           span: SyntaxHighlighter.Span,
                           markdown: String,
                           ordered: Bool,
                           checkbox: SyntaxHighlighter.Span.Kind.CheckboxState?,
                           cursorInToken: Bool) {
        // Indentation model (Apple Notes style): each nesting level steps
        // in by one marker "slot" (pointSize-wide icon + a space), so a
        // child's marker lands under its parent's content. All list types
        // share the same slot, so their text lines up. The leading
        // whitespace is hidden (by the delimiter styling) and the indent
        // comes entirely from the paragraph style.
        let markerStr = (markdown as NSString).substring(to: span.contentRange.location)
        let leadingWS = markerStr.prefix(while: { $0 == " " || $0 == "\t" })
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
        let slotWidth = bodyFont.pointSize + spaceWidth
        let depth = listDepth(leadingWhitespace: String(leadingWS))
        let markerStart = listPadding + CGFloat(depth) * slotWidth
        let contentIndent = markerStart + slotWidth
        // The visible marker text ("- ", "1. ", "- [ ] "), without the
        // leading whitespace (which we hide below).
        let markerText = String(markerStr.dropFirst(leadingWS.count))
        let markerWidth = (markerText as NSString).size(withAttributes: [.font: bodyFont]).width
        let firstLineIndent: CGFloat
        // For an active bullet we left-shift the raw "-" onto the dot's
        // column; this kern widens its trailing space so the content
        // still begins at contentIndent (set after the paragraph style).
        var activeBulletSpaceKern: CGFloat = 0
        if ordered || (cursorInToken && checkbox != nil) {
            // Ordered marker, or an active checkbox: right-align the marker
            // into its slot so the content begins at `contentIndent` — the
            // same place as the rendered (inactive) form. This keeps the
            // item aligned at every depth (and clicking in doesn't shift
            // the text), while leaving the raw "1." / "- [ ]" editable.
            // Wrapped lines hang at contentIndent via headIndent.
            firstLineIndent = max(2, contentIndent - markerWidth)
        } else if cursorInToken {
            // Active bullet: sit the raw "-" on the dot's column instead of
            // right-aligning it into the slot, so the marker doesn't jump
            // sideways when you click into the item. The inactive dot is
            // centered in a pointSize-wide box at markerStart, so center the
            // dash there too; the kern below keeps the content at
            // contentIndent.
            let dashWidth = ("-" as NSString).size(withAttributes: [.font: bodyFont]).width
            firstLineIndent = max(2, markerStart + (bodyFont.pointSize - dashWidth) / 2)
            activeBulletSpaceKern = max(0, contentIndent - (firstLineIndent + markerWidth))
        } else {
            // Inactive bullet/checkbox: the marker icon sits at markerStart.
            firstLineIndent = markerStart
        }
        // Hide the leading indentation — the indent is provided entirely by
        // the paragraph style. swift-markdown's list-item delimiter range
        // starts at the marker and excludes this whitespace, so without
        // hiding it here those spaces render visibly and push the first line
        // right, breaking alignment with the hanging (wrapped-line) indent.
        // (The deep-indent rescue parser already includes the whitespace in
        // its delimiter; the delimiter styling below avoids re-showing it.)
        let wsLen = leadingWS.count
        if wsLen > 0 {
            let lead = NSRange(location: 0, length: wsLen)
            result.addAttribute(.font, value: hiddenFont, range: lead)
            result.addAttribute(.foregroundColor, value: NSColor.clear, range: lead)
        }
        // Apply paragraph style from position 0 — NSTextView uses the paragraph
        // style from the first character of a paragraph.
        result.addAttribute(.paragraphStyle,
                            value: listParagraphStyle(firstLineIndent: firstLineIndent, contentIndent: contentIndent),
                            range: NSRange(location: 0, length: result.length))

        if depth > 0 {
            let guideOffsets = (0..<depth).map {
                listPadding + CGFloat($0) * slotWidth + bodyFont.pointSize / 2
            }
            result.addAttribute(
                .blockDecoration,
                value: BlockDecoration(.indentGuides(
                    xOffsets: guideOffsets,
                    color: NSColor.tertiaryLabelColor.withAlphaComponent(0.45)
                )),
                range: NSRange(location: 0, length: result.length)
            )
        }
        // Active bullet: widen the marker's trailing space so the content
        // lands at contentIndent even though the "-" sits on the dot column.
        if activeBulletSpaceKern > 0, span.contentRange.location > 0,
           span.contentRange.location <= result.length {
            result.addAttribute(.kern, value: activeBulletSpaceKern,
                                range: NSRange(location: span.contentRange.location - 1, length: 1))
        }
        // Strikethrough checked items
        if !ordered, checkbox == .checked {
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)
            result.addAttribute(.foregroundColor, value: syntaxDimColor, range: span.contentRange)
        }
    }

    /// Finalizes physical continuation paragraphs after every syntax span and
    /// delimiter has been styled. CommonMark exposes continuation indentation
    /// as delimiter whitespace for nested items, so doing this in the main
    /// list-span pass lets the later delimiter pass collapse it a second time.
    /// This final pass makes the list content column authoritative.
    func finalizeListContinuationParagraphs(_ result: NSMutableAttributedString,
                                             span: SyntaxHighlighter.Span,
                                             markdown: String,
                                             cursorPosition: Int?) {
        let markerStr = (markdown as NSString).substring(to: span.contentRange.location)
        let leadingWS = markerStr.prefix(while: { $0 == " " || $0 == "\t" })
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
        let slotWidth = bodyFont.pointSize + spaceWidth
        let depth = listDepth(leadingWhitespace: String(leadingWS))
        let contentIndent = listPadding + CGFloat(depth + 1) * slotWidth
        let nsMarkdown = markdown as NSString
        var lineStart = 0
        while lineStart < span.fullRange.upperBound {
            let search = NSRange(location: lineStart,
                                 length: span.fullRange.upperBound - lineStart)
            let newline = nsMarkdown.range(of: "\n", options: [], range: search)
            guard newline.location != NSNotFound else { break }
            let continuationStart = newline.upperBound
            guard continuationStart < span.fullRange.upperBound else { break }
            let tail = NSRange(location: continuationStart,
                               length: span.fullRange.upperBound - continuationStart)
            let nextNewline = nsMarkdown.range(of: "\n", options: [], range: tail)
            let lineEnd = nextNewline.location == NSNotFound
                ? span.fullRange.upperBound : nextNewline.location
            let lineRange = NSRange(location: continuationStart,
                                    length: max(0, lineEnd - continuationStart))
            let lineText = nsMarkdown.substring(with: lineRange)
            let leading = lineText.prefix(while: { $0 == " " || $0 == "\t" })
            let leadingLength = (String(leading) as NSString).length
            let caretOnLine = cursorPosition.map {
                $0 >= continuationStart && $0 <= lineEnd
            } ?? false
            let visibleWhitespaceWidth = caretOnLine
                ? (String(leading) as NSString).size(withAttributes: [.font: bodyFont]).width
                : 0
            let continuationStyle = listParagraphStyle(
                firstLineIndent: max(2, contentIndent - visibleWhitespaceWidth),
                contentIndent: contentIndent
            )
            result.addAttribute(.paragraphStyle, value: continuationStyle, range: lineRange)
            if leadingLength > 0 {
                let whitespaceRange = NSRange(location: continuationStart, length: leadingLength)
                if caretOnLine {
                    // Explicitly restore source whitespace after delimiter
                    // styling so its measured width matches the compensation
                    // in `firstLineHeadIndent` at every nesting depth.
                    result.addAttribute(.font, value: bodyFont, range: whitespaceRange)
                    result.addAttribute(.foregroundColor, value: syntaxDimColor,
                                        range: whitespaceRange)
                } else {
                    result.addAttribute(.font, value: hiddenFont, range: whitespaceRange)
                    result.addAttribute(.foregroundColor, value: NSColor.clear,
                                        range: whitespaceRange)
                }
            }
            lineStart = lineEnd
        }
    }
}

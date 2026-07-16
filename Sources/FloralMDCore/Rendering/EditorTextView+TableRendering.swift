import AppKit

/// Table styling: the largest single case of the `styleBlock` switch. When the
/// caret is inside, the table shows as dimmed monospace; otherwise it's laid out
/// with a bold header, hidden pipes, kern-padded columns, and drawn borders (via
/// a `.tableRow` BlockDecoration). Row parsing helpers live in
/// EditorTextView+TableSupport; extracted from EditorTextView+Rendering.
extension EditorTextView {

    /// Styles the `.table` content for one span. The caller has already
    /// bounds-checked `span.fullRange` against `result`.
    func styleTableSpan(_ result: NSMutableAttributedString,
                        span: SyntaxHighlighter.Span,
                        cursorInToken: Bool) {
        if cursorInToken {
            // Active: monospace, all pipes dimmed
            result.addAttribute(.font, value: tableFont, range: span.fullRange)
            let nsStr = (result.string as NSString)
            var sr = span.fullRange
            while sr.length > 0 {
                let pr = nsStr.range(of: "|", options: [], range: sr)
                guard pr.location != NSNotFound else { break }
                result.addAttribute(.foregroundColor, value: syntaxDimColor, range: pr)
                let ns = pr.upperBound
                sr = NSRange(location: ns, length: max(0, span.fullRange.upperBound - ns))
            }
        } else {
            // Non-active: bold header, hidden pipes, column-width alignment
            // via kern, drawn vertical + horizontal borders via TableRowTextBlock,
            // with cell padding for breathing room.
            let tableNS = (result.string as NSString)
            let tableStr = tableNS.substring(with: span.fullRange)
            let lines = tableStr.components(separatedBy: "\n")

            let cellHPad = bodyFont.pointSize * 0.3
            let cellVPad = bodyFont.pointSize * 0.15

            // --- Style each cell's inline markdown and measure the result ---
            // Each cell runs through styleBlock so `**bold**`, `code`, links,
            // ==marks== etc. render inside tables; hidden delimiters measure
            // ~zero, so column widths reflect what's actually visible. Header
            // cells are bolded before measuring.
            // ponytail: block-level markdown in a cell (`# x`, `- x`) keeps its
            // fonts but loses its block chrome (paragraph styles / decorations
            // are row-owned, see the transplant below); tall math or image
            // overlays get no extra line height in cells.
            let headerCells = splitTableRow(lines[0])
            let numCols = headerCells.count
            guard numCols > 0 else { return }
            var colWidths = [CGFloat](repeating: 0, count: numCols)
            // Per line: the cell's character range within the line + its
            // styled form (empty for the separator row).
            var rowCells: [[(start: Int, end: Int, styled: NSAttributedString)]] = []
            for (li, line) in lines.enumerated() {
                guard li != 1 else { rowCells.append([]); continue }
                let lineNS = line as NSString
                var cells: [(start: Int, end: Int, styled: NSAttributedString)] = []
                for cr in cellRanges(in: lineNS) {
                    let text = lineNS.substring(with: NSRange(location: cr.start,
                                                              length: cr.end - cr.start))
                    let styled = NSMutableAttributedString(
                        attributedString: styleBlock(text, cursorPosition: nil))
                    if li == 0 {
                        styled.enumerateAttribute(
                            .font, in: NSRange(location: 0, length: styled.length)
                        ) { value, r, _ in
                            guard let f = value as? NSFont else { return }
                            styled.addAttribute(
                                .font,
                                value: NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask),
                                range: r)
                        }
                    }
                    cells.append((cr.start, cr.end, styled))
                }
                rowCells.append(cells)
                for ci in 0..<min(cells.count, numCols) {
                    colWidths[ci] = max(colWidths[ci], cells[ci].styled.size().width)
                }
            }
            // Add horizontal padding to each column, then fit the shared grid
            // into the editor. Cells are drawn independently below, so every
            // column can wrap without moving any of the shared borders.
            for ci in 0..<numCols {
                colWidths[ci] += 2 * cellHPad
            }
            colWidths = fittedTableColumnWidths(
                colWidths,
                maximumWidth: max(1, availableContentWidth - cellHPad),
                minimumWidth: bodyFont.pointSize * 5
            )

            // Column-border X offsets (between columns) and total width.
            // Each border is drawn cellHPad before the column boundary
            // so the 2*cellHPad per column splits evenly: hPad of right
            // padding for the current cell, hPad of left padding for the next.
            var borderXOffsets: [CGFloat] = []
            var cumX: CGFloat = 0
            for ci in 0..<numCols {
                cumX += colWidths[ci]
                if ci < numCols - 1 { borderXOffsets.append(cumX - cellHPad) }
            }
            let totalWidth = cumX

            // Per-column alignment from the separator row (`:--`/`:-:`/`--:`).
            let aligns = tableColumnAlignments(separatorRow: lines.count > 1 ? lines[1] : "",
                                               count: numCols)

            // --- Style each row ---
            var lineOffset = span.fullRange.location
            for (i, line) in lines.enumerated() {
                let lineLen = (line as NSString).length
                let lineRange = NSRange(location: lineOffset, length: lineLen)
                guard lineRange.upperBound <= result.length else { break }
                // Row geometry via the paragraph style; the borders are
                // drawn by a .tableRow BlockDecoration. Vertical padding
                // becomes paragraph spacing (row gap = trailing + leading
                // spacing = 2*cellVPad, same as the old block padding).
                let ps = NSMutableParagraphStyle()
                ps.lineSpacing = 0
                ps.firstLineHeadIndent = cellHPad
                ps.headIndent = cellHPad
                if i == 1 {
                    // Separator row: its text is hidden; force a thin
                    // strip and draw the horizontal rule through it.
                    ps.minimumLineHeight = 4
                    ps.maximumLineHeight = 4
                    ps.paragraphSpacingBefore = 0
                    ps.paragraphSpacing = 0
                } else {
                    var drawnCells: [NSAttributedString] = []
                    var rowContentHeight: CGFloat = bodyFont.ascender - bodyFont.descender
                    for ci in 0..<numCols {
                        let source = (i < rowCells.count && ci < rowCells[i].count)
                            ? rowCells[i][ci].styled
                            : NSAttributedString(string: "", attributes: baseAttributes)
                        let cell = NSMutableAttributedString(attributedString: source)
                        let cellParagraph = NSMutableParagraphStyle()
                        let contentWidth = max(1, colWidths[ci] - 2 * cellHPad)
                        cellParagraph.lineBreakMode = tableCellNeedsCharacterWrapping(
                            cell, contentWidth: contentWidth
                        ) ? .byCharWrapping : .byWordWrapping
                        switch aligns[ci] {
                        case .left: cellParagraph.alignment = .left
                        case .center: cellParagraph.alignment = .center
                        case .right: cellParagraph.alignment = .right
                        }
                        if cell.length > 0 {
                            cell.addAttribute(.paragraphStyle, value: cellParagraph,
                                              range: NSRange(location: 0, length: cell.length))
                        }
                        let bounds = cell.boundingRect(
                            with: CGSize(width: contentWidth,
                                         height: CGFloat.greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]
                        )
                        rowContentHeight = max(rowContentHeight, ceil(bounds.height))
                        drawnCells.append(cell)
                    }
                    let rowHeight = rowContentHeight + 2 * cellVPad
                    ps.minimumLineHeight = rowHeight
                    ps.maximumLineHeight = rowHeight
                    ps.paragraphSpacingBefore = (i == 0)
                        ? bodyParagraphStyle.paragraphSpacingBefore : 0
                    ps.paragraphSpacing = 0
                    result.addAttribute(
                        .tableRowPresentation,
                        value: TableRowPresentation(
                            cells: drawnCells,
                            columnWidths: colWidths,
                            horizontalPadding: cellHPad,
                            verticalPadding: cellVPad
                        ),
                        range: lineRange
                    )
                }
                result.addAttribute(.paragraphStyle, value: ps, range: lineRange)
                result.addAttribute(
                    .blockDecoration,
                    value: BlockDecoration(.tableRow(columnXOffsets: borderXOffsets,
                                                     width: totalWidth,
                                                     leftInset: cellHPad,
                                                                      separator: i == 1,
                                                                      bottomBorder: i > 1)),
                    range: lineRange)

                if i == 1 {
                    // Separator row: hide all text
                    result.addAttribute(.font, value: hiddenFont, range: lineRange)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                } else {
                    // The custom fragment draws the styled cells. Keep the raw
                    // Markdown in storage for editing and hit-testing, but make
                    // its ordinary glyph pass invisible while the row is idle.
                    result.addAttribute(.font, value: hiddenFont, range: lineRange)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                    result.removeAttribute(.backgroundColor, range: lineRange)
                    result.removeAttribute(.underlineStyle, range: lineRange)
                    result.removeAttribute(.strikethroughStyle, range: lineRange)
                }

                // Hide all structural pipes (zero-width + clear). A `\|` is
                // escaped cell content, not a separator — leave it visible
                // (its `\` is already hidden by the cell's escape span).
                let lineNS = line as NSString
                for ci in 0..<lineNS.length {
                    if lineNS.character(at: ci) == 0x7C,
                       !(ci > 0 && lineNS.character(at: ci - 1) == 0x5C) {
                        let pipeRange = NSRange(location: lineOffset + ci, length: 1)
                        result.addAttribute(.font, value: hiddenFont, range: pipeRange)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: pipeRange)
                    }
                }

                lineOffset += lineLen + 1
            }
        }
    }
}

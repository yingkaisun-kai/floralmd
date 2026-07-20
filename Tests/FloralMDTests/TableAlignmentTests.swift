// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import Foundation
import AppKit
@testable import FloralMDCore

// GFM table column alignment (`:--`/`:-:`/`--:`) applied in the live editor.
// Inactive rows carry a custom cell presentation: all rows share column widths,
// while each cell owns its alignment and wraps inside its column rectangle.

@Suite("Table column alignment — parsing")
struct TableAlignmentParseTests {

    @Test("Separator row maps to left/center/right")
    func mixed() {
        #expect(tableColumnAlignments(separatorRow: "|:--|:-:|--:|", count: 3)
                == [.left, .center, .right])
    }

    @Test("Plain `---` columns default to left")
    func plain() {
        #expect(tableColumnAlignments(separatorRow: "| --- | --- |", count: 2)
                == [.left, .left])
    }

    @Test("Missing cells pad with .left")
    func shortRow() {
        #expect(tableColumnAlignments(separatorRow: "|--:|", count: 3)
                == [.right, .left, .left])
    }

    @Test("A backslash-escaped pipe does not split a cell")
    func escapedPipeNotSeparator() {
        #expect(splitTableRow("| a \\| b | c |").count == 2)
    }

    @Test("An empty middle cell keeps the following cell in column three")
    func emptyMiddleCell() {
        let ranges = cellRanges(in: "| a || c |" as NSString)
        #expect(ranges.count == 3)
        #expect(ranges[1].start == ranges[1].end)
    }

    @Test("An oversized column cannot monopolize a three-column table")
    func oversizedColumnIsCapped() {
        let widths = fittedTableColumnWidths(
            [1_000, 80, 80], maximumWidth: 900, minimumWidth: 70
        )
        #expect(widths[0] <= 405.5)
        #expect(widths.reduce(0, +) <= 900.5)
    }

    @Test("Short tables expand to the requested minimum table width")
    func shortTableUsesMinimumWidth() {
        let widths = fittedTableColumnWidths(
            [120, 80, 60], maximumWidth: 900, minimumWidth: 70,
            minimumTableWidth: 600
        )
        #expect(abs(widths.reduce(0, +) - 600) < 0.5)
        #expect(widths[0] > 120)
        #expect(widths[1] > 80)
        #expect(widths[2] > 60)
    }

    @Test("Only an unbroken run wider than its cell needs character wrapping")
    func characterWrapDetection() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        #expect(tableCellNeedsCharacterWrapping(
            NSAttributedString(string: "ordinary words wrap", attributes: attrs),
            contentWidth: 80
        ) == false)
        #expect(tableCellNeedsCharacterWrapping(
            NSAttributedString(string: String(repeating: "abcdef", count: 8), attributes: attrs),
            contentWidth: 80
        ))
    }
}

@Suite("Table column alignment — rendering")
@MainActor
struct TableAlignmentRenderTests {

    /// Offset of the leading `|` of the table's last (data) row.
    private func lastRowStart(_ styled: NSAttributedString) -> Int {
        let s = styled.string as NSString
        let nl = s.range(of: "\n", options: .backwards)
        return nl.location == NSNotFound ? 0 : nl.location + 1
    }

    private func presentation(at offset: Int, in styled: NSAttributedString)
        -> TableRowPresentation? {
        styled.attribute(.tableRowPresentation, at: offset,
                         effectiveRange: nil) as? TableRowPresentation
    }

    private func alignment(of cell: NSAttributedString) -> NSTextAlignment? {
        guard cell.length > 0 else { return nil }
        return (cell.attribute(.paragraphStyle, at: 0,
                               effectiveRange: nil) as? NSParagraphStyle)?.alignment
    }

    private func fragmentGeometry(in editor: EditorTextView, at rawOffset: Int)
        -> (layoutX: CGFloat, surfaceX: CGFloat, lineX: CGFloat)? {
        guard let textLayoutManager = editor.textLayoutManager,
              let location = textLayoutManager.location(
                textLayoutManager.documentRange.location, offsetBy: rawOffset
              ),
              let fragment = textLayoutManager.textLayoutFragment(for: location),
              let firstLine = fragment.textLineFragments.first else {
            return nil
        }
        return (
            fragment.layoutFragmentFrame.minX,
            fragment.renderingSurfaceBounds.minX,
            firstLine.typographicBounds.minX
        )
    }

    @Test("Right-aligned column keeps right alignment in its cell rectangle")
    func rightAlign() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| aaa | bbb |\n|--:|--:|\n| x | y |", cursorPosition: nil)
        let start = lastRowStart(styled)
        let row = presentation(at: start, in: styled)
        #expect(row != nil)
        #expect(row.map { alignment(of: $0.cells[0]) } == .right)
    }

    @Test("Left-aligned column keeps left alignment in its cell rectangle")
    func leftAlign() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| aaa | bbb |\n|---|---|\n| x | y |", cursorPosition: nil)
        let start = lastRowStart(styled)
        let row = presentation(at: start, in: styled)
        #expect(row != nil)
        #expect(row.map { alignment(of: $0.cells[0]) } == .left)
    }

    @Test("Active table has no custom presentation (raw monospace)")
    func activeUnaffected() {
        let editor = makeEditor()
        let table = "| aaa | bbb |\n|--:|--:|\n| x | y |"
        let styled = editor.styleBlock(table, cursorPosition: 2)
        #expect(styled.attribute(.tableRowPresentation, at: 0,
                                 effectiveRange: nil) == nil)
    }

    @Test("Column width uses the styled cell width, not the raw source width")
    func styledWidthAlignment() {
        let editor = makeEditor()
        let marked = editor.styleBlock("| **wide** | b |\n|---|---|\n| wide | y |",
                                       cursorPosition: nil)
        let plain = editor.styleBlock("| wide | b |\n|---|---|\n| wide | y |",
                                      cursorPosition: nil)
        let markedWidth = presentation(at: 0, in: marked)?.columnWidths[0] ?? 0
        let plainWidth = presentation(at: 0, in: plain)?.columnWidths[0] ?? 0
        let twoChars = "aa".size(withAttributes: [.font: editor.bodyFont]).width
        #expect(abs(markedWidth - plainWidth) < twoChars)
    }

    @Test("Open tables draw only internal horizontal rules")
    func internalHorizontalRules() {
        let editor = makeEditor()
        let styled = editor.styleBlock(
            "| A | B |\n| --- | --- |\n| one | two |\n| three | four |",
            cursorPosition: nil
        )
        let source = styled.string as NSString
        var rowStarts = [0]
        for offset in 0..<source.length where source.character(at: offset) == 10 {
            rowStarts.append(offset + 1)
        }

        let borders = rowStarts.compactMap { offset -> Bool? in
            guard let decoration = styled.attribute(.blockDecoration, at: offset,
                                                    effectiveRange: nil) as? BlockDecoration,
                  case .tableRow(_, _, _, let bottomBorder) = decoration.kind else {
                return nil
            }
            return bottomBorder
        }
        #expect(borders == [false, false, true, false])
    }

    @Test("Long cells in every column wrap independently on one shared grid")
    func everyCellWrapsOnSharedGrid() {
        let editor = makeEditor()
        editor.frame.size.width = 420
        editor.textContainer?.size.width = 420
        let styled = editor.styleBlock(
            "| First | Second |\n| --- | --- |\n| This first cell contains enough words to wrap independently | This second cell also contains enough words to wrap independently |",
            cursorPosition: nil
        )
        let start = lastRowStart(styled)
        guard let row = presentation(at: start, in: styled) else {
            Issue.record("expected a table-row presentation")
            return
        }
        #expect(row.cells.count == 2)
        #expect(row.columnWidths.count == 2)
        for ci in 0..<2 {
            let width = row.columnWidths[ci] - 2 * row.horizontalPadding
            let bounds = row.cells[ci].boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            #expect(bounds.height > editor.bodyFont.ascender - editor.bodyFont.descender)
        }

    }

    @Test("A trailing newline does not add a bottom rule")
    func trailingNewlineHasNoBottomRule() {
        let editor = makeEditor()
        let styled = editor.styleBlock(
            "| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n",
            cursorPosition: nil
        )
        let lastRow = (styled.string as NSString).range(of: "| three").location
        guard let decoration = styled.attribute(.blockDecoration, at: lastRow,
                                                 effectiveRange: nil) as? BlockDecoration,
              case .tableRow(_, _, _, let bottomBorder) = decoration.kind else {
            Issue.record("expected a table-row decoration")
            return
        }
        #expect(!bottomBorder)
    }

    @Test("Multiline cells inherit the user's line spacing")
    func cellLineSpacing() {
        var theme = EditorTheme.default
        theme.lineSpacing = 12
        let editor = makeEditor()
        editor.applyTheme(theme, persist: false)
        editor.frame.size.width = 360
        editor.textContainer?.size.width = 360
        let styled = editor.styleBlock(
            "| First | Second |\n| --- | --- |\n| This cell contains enough ordinary words to wrap | short |",
            cursorPosition: nil
        )
        let start = lastRowStart(styled)
        guard let row = presentation(at: start, in: styled),
              let paragraph = row.cells[0].attribute(
                .paragraphStyle, at: 0, effectiveRange: nil
              ) as? NSParagraphStyle else {
            Issue.record("expected a rendered cell paragraph style")
            return
        }
        #expect(paragraph.lineSpacing == 12)
        #expect(paragraph.paragraphSpacingBefore == 0)
        #expect(paragraph.paragraphSpacing == 0)
    }

    @Test("Compact resize relays out every table row on one shared origin")
    func compactResizeUsesSharedOrigin() {
        let editor = makeEditor()
        editor.frame.size.width = 900
        editor.textContainer?.size.width = 900
        editor.maxContentWidthPoints = 500
        let table = """
        | Header 1 | Header 2 | Header 3 |
        | --- | --- | --- |
        | Cell 1 | Cell 2 | Cell 3 |
        | C 4 | Cell 5 | Cell 6 |
        """
        let document = "outside\n\n" + table
        editor.loadContent(document)
        activateBlock(0, in: editor)
        ensureFullLayout(editor)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        editor.setFrameSize(NSSize(width: 550, height: editor.frame.height))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        let source = document as NSString
        let rowPrefixes = ["| Header 1", "| ---", "| Cell 1", "| C 4"]
        let geometries: [(layoutX: CGFloat, surfaceX: CGFloat, lineX: CGFloat)] =
            rowPrefixes.compactMap { prefix in
                let range = source.range(of: prefix)
                guard range.location != NSNotFound else { return nil }
                return fragmentGeometry(in: editor, at: range.location)
            }

        #expect(geometries.count == rowPrefixes.count)
        guard let first = geometries.first else { return }
        for geometry in geometries.dropFirst() {
            #expect(abs(geometry.layoutX - first.layoutX) < 0.5)
            #expect(abs(geometry.surfaceX - first.surfaceX) < 0.5)
            #expect(abs(geometry.lineX - first.lineX) < 0.5)
        }
    }

    @Test("Open-table styling has no vertical rules with a trailing newline",
          .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func trailingNewlineKeepsFinalRowAligned() {
        let editor = makeEditor()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.documentView = editor
        window.contentView = scrollView
        window.makeFirstResponder(editor)
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 24, height: 18)
        let document = "\n\n| Header 1 | Header 2 | Header 3 |\n| --- | --- | --- |\n| Cell 1 | Cell 2 | Cell 3 |\n| Cell 4 | Cell 5 | Cell 6 |\n"
        editor.loadContent(document)
        guard let tableIndex = editor.blocks.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("expected table block")
            return
        }
        activateBlock(tableIndex, in: editor)
        ensureFullLayout(editor)
        activateBlock(0, in: editor)
        ensureFullLayout(editor)
        drainAllStyling(editor)
        editor.sizeToFit()
        ensureFullLayout(editor)
        editor.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let bounds = scrollView.bounds
        guard let bitmap = scrollView.bitmapImageRepForCachingDisplay(in: bounds) else {
            Issue.record("could not create bitmap")
            return
        }
        scrollView.cacheDisplay(in: bounds, to: bitmap)
        var strongVerticalRules: [Int] = []
        let xRange = 40..<min(bitmap.pixelsWide, 520)
        let yRange = 80..<min(bitmap.pixelsHigh, 330)
        for x in xRange {
            var score = 0
            for y in yRange {
                guard let sourceColor = bitmap.colorAt(x: x, y: y),
                      let color = sourceColor.usingColorSpace(.deviceRGB) else { continue }
                let red = Int((color.redComponent * 255).rounded())
                let green = Int((color.greenComponent * 255).rounded())
                let blue = Int((color.blueComponent * 255).rounded())
                let redGreen = red - green
                let redBlue = red - blue
                if (190...245).contains(red),
                   (-2...2).contains(redGreen),
                   (-2...2).contains(redBlue) {
                    score += 1
                }
            }
            if score > 150 { strongVerticalRules.append(x) }
        }
        #expect(strongVerticalRules.isEmpty,
                "expected no vertical table rules, got \(strongVerticalRules)")
    }

}

@Suite("Table cell inline styling")
@MainActor
struct TableInlineStylingTests {

    private func table(_ cell: String) -> NSAttributedString {
        makeEditor().styleBlock("| \(cell) | b |\n|---|---|\n| x | y |", cursorPosition: nil)
    }

    private func presentation(at offset: Int, in styled: NSAttributedString)
        -> TableRowPresentation? {
        styled.attribute(.tableRowPresentation, at: offset,
                         effectiveRange: nil) as? TableRowPresentation
    }

    private func cell(_ index: Int, at rowOffset: Int,
                      in styled: NSAttributedString) -> NSAttributedString? {
        guard let row = presentation(at: rowOffset, in: styled),
              index < row.cells.count else { return nil }
        return row.cells[index]
    }

    @Test("Bold in a header cell renders bold at body size")
    func boldCell() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| **bold** | y |", cursorPosition: nil)
        let start = (styled.string as NSString).range(of: "\n", options: .backwards).location + 1
        guard let rendered = cell(0, at: start, in: styled) else {
            Issue.record("expected rendered data cell")
            return
        }
        let bold = (rendered.string as NSString).range(of: "bold")
        let f = rendered.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        #expect(f != nil && NSFontManager.shared.traits(of: f!).contains(.boldFontMask))
        // Its ** delimiters are hidden.
        let d = rendered.attribute(.font, at: bold.location - 1, effectiveRange: nil) as? NSFont
        #expect((d?.pointSize ?? 99) < 1.0)
    }

    @Test("Inline code in a cell gets the mono font")
    func codeCell() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| `code` | y |", cursorPosition: nil)
        let start = (styled.string as NSString).range(of: "\n", options: .backwards).location + 1
        guard let rendered = cell(0, at: start, in: styled) else {
            Issue.record("expected rendered data cell")
            return
        }
        let code = (rendered.string as NSString).range(of: "code")
        let f = rendered.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont
        #expect(f == editor.inlineCodeFont)
    }

    @Test("Link in a cell is colored and carries its destination")
    func linkCell() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| [x](http://e.com) | y |", cursorPosition: nil)
        let start = (styled.string as NSString).range(of: "\n", options: .backwards).location + 1
        guard let rendered = cell(0, at: start, in: styled) else {
            Issue.record("expected rendered data cell")
            return
        }
        let x = (rendered.string as NSString).range(of: "[x]")
        let dest = rendered.attribute(.editorLinkURL, at: x.location + 1,
                                      effectiveRange: nil) as? String
        #expect(dest == "http://e.com")
    }

    @Test("Header-row styling stays bold when a cell has italic (boldItalic)")
    func headerItalicCell() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| *it* | b |\n|---|---|\n| x | y |", cursorPosition: nil)
        guard let rendered = cell(0, at: 0, in: styled) else {
            Issue.record("expected rendered header cell")
            return
        }
        let it = (rendered.string as NSString).range(of: "it")
        let f = rendered.attribute(.font, at: it.location, effectiveRange: nil) as? NSFont
        let traits = f.map { NSFontManager.shared.traits(of: $0) } ?? []
        #expect(traits.contains(.boldFontMask))
        #expect(traits.contains(.italicFontMask))
    }

    @Test("Escaped pipe in a data cell stays visible; structural pipes stay hidden")
    func escapedPipeStaysVisible() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| x \\| y | z |", cursorPosition: nil)
        let s = styled.string as NSString
        let lastRow = s.range(of: "\n", options: .backwards).location + 1
        guard let rendered = cell(0, at: lastRow, in: styled) else {
            Issue.record("expected rendered data cell")
            return
        }
        let escaped = (rendered.string as NSString).range(of: "\\|")
        #expect(escaped.location != NSNotFound)
        let escapedPipeFont = rendered.attribute(.font, at: escaped.location + 1,
                                                 effectiveRange: nil) as? NSFont
        #expect((escapedPipeFont?.pointSize ?? 0) >= 1.0)

        // A structural pipe (the leading pipe of the data row) stays hidden.
        let structuralPipeFont = styled.attribute(.font, at: lastRow, effectiveRange: nil) as? NSFont
        #expect((structuralPipeFont?.pointSize ?? 99) < 1.0)
    }

    @Test("Row paragraph geometry survives cell styling (table owns it)")
    func rowGeometryPreserved() {
        let styled = table("**b**")
        // First char of the header row still carries the table's paragraph
        // style (indent = cell padding), not styleBlock's body style.
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps != nil && ps!.firstLineHeadIndent > 0)
        // And the row decoration is a table row.
        #expect(styled.attribute(.blockDecoration, at: 0, effectiveRange: nil) != nil)
    }
}

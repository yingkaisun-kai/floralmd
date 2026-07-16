import AppKit
import Testing
@testable import FloralMDCore

@Suite("Document minimap coordinate model")
struct DocumentMinimapCoordinateModelTests {
    @Test("Short documents keep a natural top-aligned height")
    func shortDocumentDoesNotStretch() {
        let source = (0..<5).map { "line \($0)" }.joined(separator: "\n")
        let model = DocumentMinimapCoordinateModel(source: source,
                                                   viewportHeight: 700,
                                                   wrapColumn: 80)

        #expect(model.semanticRows.count == 5)
        #expect(model.rowPitch == 3)
        #expect(model.contentRange.lowerBound == 4)
        #expect(model.contentRange.upperBound == 19)
    }

    @Test("Medium documents retain natural pitch until they need compression")
    func mediumDocumentRetainsNaturalPitch() {
        let source = (0..<120).map { "paragraph \($0)" }.joined(separator: "\n")
        let model = DocumentMinimapCoordinateModel(source: source,
                                                   viewportHeight: 700,
                                                   wrapColumn: 80)

        #expect(model.semanticRows.count == 120)
        #expect(model.rowPitch == 3)
        #expect(model.contentRange.upperBound == 364)
    }

    @Test("Long documents compress only after exceeding usable height")
    func longDocumentCompresses() {
        let source = (0..<1_000).map { "line \($0)" }.joined(separator: "\n")
        let model = DocumentMinimapCoordinateModel(source: source,
                                                   viewportHeight: 700,
                                                   wrapColumn: 80)

        #expect(model.semanticRows.count == 1_000)
        #expect(abs(model.rowPitch - 0.692) < 0.001)
        #expect(model.contentRange.upperBound == 696)
    }

    @Test("Wrapped source positions and minimap clicks use the same rows")
    func wrappedLineRoundTrips() {
        let source = String(repeating: "abcdefghij", count: 24)
        let model = DocumentMinimapCoordinateModel(source: source,
                                                   viewportHeight: 700,
                                                   wrapColumn: 40)

        #expect(model.semanticRows.count == 6)
        let middleY = model.y(forUTF16Offset: 120)
        #expect(abs(middleY - 13) < 0.001)
        #expect(abs(model.sourceOffset(atY: middleY) - 120) <= 1)
    }

    @Test("Many wrapped lines contribute their semantic row count before compression")
    func manyWrappedLines() {
        let line = String(repeating: "x", count: 200)
        let source = Array(repeating: line, count: 100).joined(separator: "\n")
        let model = DocumentMinimapCoordinateModel(source: source,
                                                   viewportHeight: 700,
                                                   wrapColumn: 40)

        #expect(model.lineCount == 100)
        #expect(model.semanticRows.count == 500)
        #expect(abs(model.rowPitch - 1.384) < 0.001)

        let sourceMiddle = (source as NSString).length / 2
        let visualMiddle = model.contentRange.lowerBound
            + (model.contentRange.upperBound - model.contentRange.lowerBound) / 2
        #expect(abs(model.y(forUTF16Offset: sourceMiddle) - visualMiddle) < 3)
        #expect(abs(model.sourceOffset(atY: visualMiddle) - sourceMiddle) < 50)
    }

    @Test("A fully visible document viewport covers only the actual minimap content")
    func fullyVisibleViewportCoversContent() {
        let source = "one\ntwo\nthree"
        let model = DocumentMinimapCoordinateModel(source: source,
                                                   viewportHeight: 700,
                                                   wrapColumn: 80)
        let viewport = model.viewportRect(
            for: NSRange(location: 0, length: (source as NSString).length)
        )

        #expect(viewport.minY == model.contentRange.lowerBound)
        #expect(viewport.maxY == model.contentRange.upperBound)
        #expect(viewport.height == 9)
    }

    @Test("Viewport, cursor, Git boundaries, and clicks share source coordinates")
    func sharedCoordinateSystem() {
        let source = "first\n" + String(repeating: "w", count: 120) + "\nlast"
        let ns = source as NSString
        let wrappedStart = ns.range(of: "w").location
        let lastStart = ns.range(of: "last").location
        let model = DocumentMinimapCoordinateModel(source: source,
                                                   viewportHeight: 300,
                                                   wrapColumn: 40)

        #expect(model.y(forLineBoundary: 1) == model.y(forUTF16Offset: wrappedStart))
        #expect(model.y(forLineBoundary: 2) == model.y(forUTF16Offset: lastStart))

        let visible = NSRange(location: wrappedStart + 40, length: 40)
        let viewport = model.viewportRect(for: visible, minimumHeight: 0)
        let clicked = model.sourceOffset(atY: viewport.midY)
        #expect(clicked >= visible.location)
        #expect(clicked <= visible.upperBound)
    }

    @Test("Source-target scrolling centers the matching TextKit 2 region without moving the caret")
    @MainActor func sourceTargetScrollsWithoutMovingCaret() {
        let editor = makeEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.documentView = editor
        window.contentView = scrollView
        window.makeFirstResponder(editor)
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]

        let source = (0..<200).map { "paragraph \($0) with enough text to render" }
            .joined(separator: "\n\n")
        editor.loadContent(source)
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()

        let target = (source as NSString).range(of: "paragraph 150").location
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollSourceOffsetToCenter(target)

        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(scrollView.contentView.bounds.origin.y > 0)
        let visible = editor.currentViewportSourceRange()
        #expect(visible?.contains(target) == true)
    }
}

import AppKit
import Testing
@testable import FloralMDCore

@Suite("Read/Edit viewport mapping")
@MainActor
struct ReadModeViewportTests {
    @Test("top-level blocks receive source-line anchors")
    func sourceLineAnchors() {
        let markdown = "# One\n\nParagraph.\n\n- item"
        let html = HTMLRenderer.render(markdown: markdown)
        #expect(html.contains("<h1 id=\"floralmd-l1\">One</h1>"))
        #expect(html.contains("<p id=\"floralmd-l3\">Paragraph.</p>"))
        #expect(html.contains("<ul id=\"floralmd-l5\">"))
        #expect(ReadModeAnchors.topLevelBlockSpans(for: markdown).map(\.startLine) == [1, 3, 5])
    }

    @Test("anchors coexist with preserved blank-line spacers")
    func anchorsAndBlankLines() {
        let html = HTMLRenderer.render(
            markdown: "first\n\n\nsecond",
            options: ReadRenderOptions(preserveBlankLines: true)
        )
        #expect(html.contains("<p id=\"floralmd-l1\">first</p>"))
        #expect(html.contains("<div class=\"blank-line\"></div>"))
        #expect(html.contains("<p id=\"floralmd-l4\">second</p>"))
    }

    @Test("UTF-16 line and offset helpers are inverse at line starts")
    func lineOffsetMapping() {
        let editor = EditorTextView.makeTextKit2(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        editor.loadContent("alpha\nemoji 😀\nomega")
        #expect(editor.offset(forLine: 1) == 0)
        #expect(editor.offset(forLine: 2) == 6)
        #expect(editor.offset(forLine: 3) == 15)
        #expect(editor.line(forOffset: editor.offset(forLine: 3)) == 3)
        #expect(editor.offset(forLine: 99) == 15)
    }
}

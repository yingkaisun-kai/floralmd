import Testing
@testable import FloralMDCore

@Suite("Document outline")
@MainActor
struct OutlineTests {
    @Test("Extracts ATX and setext headings in document order")
    func extractsHeadings() {
        let editor = makeEditor()
        editor.loadContent("# First\n\nBody\n\nThird\n---\n\n### Deep")

        #expect(editor.outlineItems() == [
            MarkdownOutlineItem(level: 1, title: "First"),
            MarkdownOutlineItem(level: 2, title: "Third"),
            MarkdownOutlineItem(level: 3, title: "Deep"),
        ])
    }

    @Test("Ignores non-heading blocks and empty headings")
    func ignoresNonHeadings() {
        let editor = makeEditor()
        editor.loadContent("Paragraph\n\n## ##\n\n- item")

        #expect(editor.outlineItems().isEmpty)
    }
}

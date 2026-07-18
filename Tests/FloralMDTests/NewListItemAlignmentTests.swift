// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
@testable import FloralMDCore

// Regression: a list marker freshly created by pressing Return (an *empty*
// list item) must keep the same hanging indent as a non-empty item. An empty
// item has no child nodes, so the marker used to be treated as content — its
// width collapsed to zero and `firstLineHeadIndent` jumped to `headIndent`,
// rendering the new marker a full slot too deep until the next edit.
@Suite("New list item alignment")
@MainActor
struct NewListItemAlignmentTests {

    private func ps(_ editor: EditorTextView, blockIdx: Int) -> NSParagraphStyle? {
        let r = editor.blocks[blockIdx].range
        return editor.textStorage?.attribute(.paragraphStyle, at: r.location,
                                             effectiveRange: nil) as? NSParagraphStyle
    }

    /// Presses Return at the end of block 0 to spawn a new empty item (block 1).
    private func spawnNewItem(_ content: String) -> EditorTextView {
        let editor = makeEditor()
        editor.loadContent(content)
        let endOfFirst = (content as NSString).range(of: "\n").location
        editor.setSelectedRange(NSRange(location: endOfFirst, length: 0))
        editor.insertNewline(nil)
        return editor
    }

    @Test("Empty bullet keeps a hanging indent (marker not collapsed into content)")
    func bullet() {
        let editor = spawnNewItem("- alpha\n- beta")
        let new = ps(editor, blockIdx: 1)
        #expect(new != nil)
        // Marker width is preserved: the first line hangs left of the content.
        #expect(new!.firstLineHeadIndent < new!.headIndent)
    }

    @Test("Empty ordered item aligns with its siblings")
    func ordered() {
        let editor = spawnNewItem("1. alpha\n2. beta")
        let sibling = ps(editor, blockIdx: 0)
        let new = ps(editor, blockIdx: 1)
        #expect(new != nil && sibling != nil)
        // SF Pro uses proportional figures, so `1. ` is narrower than `2. `.
        // Ordered markers are intentionally right-aligned,
        // so compare their right edges rather than their left origins.
        let siblingWidth = ("1. " as NSString).size(withAttributes: [.font: editor.bodyFont]).width
        let newWidth = ("2. " as NSString).size(withAttributes: [.font: editor.bodyFont]).width
        let siblingRightEdge = sibling!.firstLineHeadIndent + siblingWidth
        let newRightEdge = new!.firstLineHeadIndent + newWidth
        #expect(abs(newRightEdge - siblingRightEdge) < 0.5)
        #expect(abs(new!.headIndent - sibling!.headIndent) < 0.5)
    }

    @Test("Empty checkbox keeps a hanging indent")
    func checkbox() {
        let editor = spawnNewItem("- [ ] alpha\n- [ ] beta")
        let new = ps(editor, blockIdx: 1)
        #expect(new != nil)
        #expect(new!.firstLineHeadIndent < new!.headIndent)
    }
}

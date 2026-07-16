import AppKit
import Testing
@testable import FloralMDCore

@Suite("Transient editor blanking")
struct TransientBlankingMechanismTests {
    @Test("Active-block restyle returns with affected fragments laid out")
    @MainActor
    func activeBlockRestyleKeepsFragmentsDrawable() {
        let editor = makeEditor()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = editor
        window.contentView = scroll
        window.makeFirstResponder(editor)
        editor.typewriterModeEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.autoresizingMask = [.width]

        let document = """
        First ordinary paragraph with enough words to wrap across more than one line \
        in the editor viewport and exercise a real visible layout fragment.

        Second paragraph contains **bold Markdown** and enough ordinary body text to \
        verify that active-block restyling does not spread hidden attributes.

        Third ordinary paragraph remains visible below the newly active paragraph.
        """
        editor.loadContent(document)
        drainAllStyling(editor)
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()

        let affected = IndexSet([0, 1])
        #expect(fragmentStates(in: editor, intersecting: affected)
            .allSatisfy { $0 == .layoutAvailable })

        let target = editor.blocks[1].range.location
        editor.recomposeDirty(affected, cursorInRaw: target)

        let states = fragmentStates(in: editor, intersecting: affected)
        #expect(!states.isEmpty && states.allSatisfy { $0 == .layoutAvailable },
                "active-block restyle returned with non-drawable fragments: \(states)")
        #expect(invalidBodyAttributeOffsets(in: editor).isEmpty,
                "active-block restyle spread hidden attributes into body characters")
    }

    @MainActor
    private func fragmentStates(
        in editor: EditorTextView,
        intersecting blockIndexes: IndexSet
    ) -> [NSTextLayoutFragment.State] {
        guard let tlm = editor.textLayoutManager else { return [] }
        let blockRanges = blockIndexes.compactMap { index in
            index < editor.blocks.count ? editor.blocks[index].range : nil
        }
        var states: [NSTextLayoutFragment.State] = []
        // No `.ensuresLayout`: this observes the state left by recomposeDirty
        // without repairing a missing fragment as a side effect of the test.
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: []
        ) { fragment in
            guard let elementRange = fragment.textElement?.elementRange else { return true }
            let start = tlm.offset(
                from: tlm.documentRange.location,
                to: elementRange.location
            )
            let end = tlm.offset(
                from: tlm.documentRange.location,
                to: elementRange.endLocation
            )
            let rawRange = NSRange(location: start, length: max(0, end - start))
            if blockRanges.contains(where: { NSIntersectionRange($0, rawRange).length > 0 }) {
                states.append(fragment.state)
            }
            return true
        }
        return states
    }

    @MainActor
    private func invalidBodyAttributeOffsets(in editor: EditorTextView) -> [Int] {
        guard let storage = editor.textStorage else { return [] }
        let source = storage.string as NSString
        return (0..<storage.length).filter { offset in
            let character = source.character(at: offset)
            guard CharacterSet.alphanumerics.contains(
                UnicodeScalar(character) ?? UnicodeScalar(0)
            ) else { return false }
            let attributes = storage.attributes(at: offset, effectiveRange: nil)
            let alpha = (attributes[.foregroundColor] as? NSColor)?.alphaComponent ?? 1
            let size = (attributes[.font] as? NSFont)?.pointSize ?? editor.bodyFont.pointSize
            return alpha < 0.5 || size < 1
        }
    }
}

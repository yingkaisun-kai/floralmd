// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
@testable import FloralMDCore

// When you click into a bullet item, the raw "-" should stay on the dot's
// column (where the rendered • sits) rather than jumping a slot to the right.
// Content must still hang at the same indent so the text doesn't move.
@Suite("Active bullet marker column")
@MainActor
struct ActiveBulletMarkerTests {

    private func laidOutX(_ rawOffset: Int, in editor: EditorTextView) -> CGFloat? {
        guard let tlm = editor.textLayoutManager,
              let location = tlm.location(tlm.documentRange.location, offsetBy: rawOffset),
              let fragment = tlm.textLayoutFragment(for: location),
              let paragraphStart = fragment.textElement?.elementRange?.location else { return nil }
        let offsetInParagraph = tlm.offset(from: paragraphStart, to: location)
        guard let line = fragment.textLineFragments.first(where: {
            NSLocationInRange(offsetInParagraph, $0.characterRange)
        }) else { return nil }
        return fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
            + line.locationForCharacter(at: offsetInParagraph).x
    }

    private func ps(_ editor: EditorTextView, _ s: String, cursor: Int?) -> NSParagraphStyle? {
        let st = editor.styleBlock(s, cursorPosition: cursor)
        return st.attribute(.paragraphStyle, at: st.length - 1, effectiveRange: nil) as? NSParagraphStyle
    }

    @Test("Active bullet marker stays on the dot column (not right-aligned into the slot)")
    func bulletStaysOnDotColumn() {
        let editor = makeEditor()
        let active = ps(editor, "- item", cursor: 3)!
        let inactive = ps(editor, "- item", cursor: nil)!
        let slot = editor.bodyFont.pointSize +
            (" " as NSString).size(withAttributes: [.font: editor.bodyFont]).width
        // The active dash sits on the inactive dot's column (within a fraction of
        // a slot), not a full slot to the right of it.
        #expect(abs(active.firstLineHeadIndent - inactive.firstLineHeadIndent) < slot * 0.5)
        // Content is unchanged so the text doesn't shift when clicking in.
        #expect(abs(active.headIndent - inactive.headIndent) < 0.5)
    }

    @Test("Active bullet kerns its trailing space so content keeps the hanging indent")
    func bulletKernsTrailingSpace() {
        let editor = makeEditor()
        let st = editor.styleBlock("- item", cursorPosition: 3)
        // "- item": the space is index 1; it carries positive kern to push the
        // content out to the content indent even though the dash sits left.
        let kern = st.attribute(.kern, at: 1, effectiveRange: nil) as? CGFloat
        #expect((kern ?? 0) > 0)
    }

    @Test("Active ordered marker still right-aligns into its slot")
    func orderedStillRightAligns() {
        let editor = makeEditor()
        let active = ps(editor, "1. item", cursor: 4)!
        // Ordered numbers keep right-alignment (periods line up), so the first
        // line indent is well right of the bullet column.
        #expect(active.firstLineHeadIndent < active.headIndent)
        #expect(active.firstLineHeadIndent > editor.listPadding + 1)
    }

    @Test("Manual continuation aligns to list content and reveals source indent on its line")
    func continuationAlignment() {
        let editor = makeEditor()
        let markdown = "- first line\n  continued line"
        let inactive = editor.styleBlock(markdown, cursorPosition: nil)
        let active = editor.styleBlock(markdown, cursorPosition: 16)
        let continuation = (markdown as NSString).range(of: "continued")
        let leading = (markdown as NSString).range(of: "  continued")
        let inactiveStyle = inactive.attribute(.paragraphStyle, at: continuation.location,
                                               effectiveRange: nil) as? NSParagraphStyle
        let activeStyle = active.attribute(.paragraphStyle, at: continuation.location,
                                           effectiveRange: nil) as? NSParagraphStyle
        #expect(inactiveStyle != nil)
        #expect(abs((inactiveStyle?.firstLineHeadIndent ?? 0) -
                    (inactiveStyle?.headIndent ?? 1)) < 0.5)
        #expect(abs((activeStyle?.headIndent ?? 0) -
                    (inactiveStyle?.headIndent ?? 1)) < 0.5)
        #expect(inactive.attribute(.foregroundColor, at: leading.location,
                                  effectiveRange: nil) as? NSColor == NSColor.clear)
        #expect(active.attribute(.foregroundColor, at: leading.location,
                                effectiveRange: nil) as? NSColor != NSColor.clear)
    }

    @Test("Nested manual continuation keeps the nested item's content column")
    func nestedContinuationAlignment() {
        let editor = makeEditor()
        editor.listIndentUnit = 2
        let markdown = "  - nested first line\n    nested continuation"
        let inactive = editor.styleBlock(markdown, cursorPosition: nil)
        let continuation = (markdown as NSString).range(of: "nested continuation")
        let leading = (markdown as NSString).range(of: "    nested continuation")
        let firstStyle = inactive.attribute(.paragraphStyle, at: 4,
                                            effectiveRange: nil) as? NSParagraphStyle
        let continuationStyle = inactive.attribute(.paragraphStyle, at: continuation.location,
                                                   effectiveRange: nil) as? NSParagraphStyle
        #expect(firstStyle != nil && continuationStyle != nil)
        #expect(abs((firstStyle?.headIndent ?? 0) -
                    (continuationStyle?.firstLineHeadIndent ?? 1)) < 0.5)
        #expect(inactive.attribute(.font, at: leading.location,
                                  effectiveRange: nil) as? NSFont == editor.hiddenFont)

        let active = editor.styleBlock(markdown, cursorPosition: continuation.location)
        let activeStyle = active.attribute(.paragraphStyle, at: continuation.location,
                                           effectiveRange: nil) as? NSParagraphStyle
        let sourceIndentWidth = ("    " as NSString).size(
            withAttributes: [.font: editor.bodyFont]
        ).width
        #expect(abs((activeStyle?.firstLineHeadIndent ?? 0) + sourceIndentWidth -
                    (firstStyle?.headIndent ?? 1)) < 0.5)
        #expect(active.attribute(.font, at: leading.location,
                                effectiveRange: nil) as? NSFont == editor.bodyFont)
    }

    @Test("Nested continuation aligns in actual TextKit layout")
    func nestedContinuationLayout() {
        let editor = makeEditor()
        editor.listIndentUnit = 2
        let markdown = "  - nested first line\n    nested continuation"
        editor.loadContent(markdown)
        let ns = markdown as NSString
        let first = ns.range(of: "nested first").location
        let continuation = ns.range(of: "nested continuation").location
        editor.recompose(cursorInRaw: continuation)
        ensureFullLayout(editor)
        let firstX = laidOutX(first, in: editor)
        let continuationX = laidOutX(continuation, in: editor)
        #expect(firstX != nil && continuationX != nil)
        // The active raw dash and rendered continuation use different glyph
        // metrics, so allow the same sub-3pt marker compensation tolerated by
        // the existing active-marker tests. A missing nesting slot is ~22pt.
        #expect(abs((firstX ?? 0) - (continuationX ?? 100)) < 3,
                "actual glyph origins must align: first=\(String(describing: firstX)), continuation=\(String(describing: continuationX))")
    }

    @Test("Deep nested continuation keeps the deep item's content column")
    func deepNestedContinuationAlignment() {
        let editor = makeEditor()
        editor.listIndentUnit = 2
        let markdown = "    - deep first line\n      deep continuation"
        let styled = editor.styleBlock(markdown, cursorPosition: nil)
        let continuation = (markdown as NSString).range(of: "deep continuation")
        let firstStyle = styled.attribute(.paragraphStyle, at: 6,
                                          effectiveRange: nil) as? NSParagraphStyle
        let continuationStyle = styled.attribute(.paragraphStyle, at: continuation.location,
                                                 effectiveRange: nil) as? NSParagraphStyle
        #expect(firstStyle != nil && continuationStyle != nil)
        #expect(abs((firstStyle?.headIndent ?? 0) -
                    (continuationStyle?.firstLineHeadIndent ?? 1)) < 0.5)
    }
}

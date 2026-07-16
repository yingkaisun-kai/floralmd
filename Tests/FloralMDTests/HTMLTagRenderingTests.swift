import Testing
import Foundation
import AppKit
@testable import FloralMDCore

// HTML tags in edit mode: every recognized tag is colored source (name red,
// brackets dimmed); a whitelist (u/kbd/mark/sub/sup) additionally renders its
// formatting when the caret is outside the token. Read mode passes raw HTML
// through per GFM, filtered by tagfilter (§6.11) + hardening.

@Suite("SyntaxHighlighter — HTML tags")
struct HTMLTagParseTests {

    private func kinds(_ text: String) -> [SyntaxHighlighter.Span.Kind] {
        SyntaxHighlighter.parse(text).map(\.kind)
    }

    @Test("Whitelisted pair → htmlFormat")
    func pair() {
        let spans = SyntaxHighlighter.parse("<u>hi</u>")
        let fmt = spans.first { if case .htmlFormat = $0.kind { return true }; return false }
        #expect(fmt != nil)
        #expect(fmt?.contentRange == NSRange(location: 3, length: 2))   // "hi"
        #expect(fmt?.delimiterRanges == [NSRange(location: 0, length: 3),   // <u>
                                         NSRange(location: 5, length: 4)])  // </u>
    }

    @Test("Unknown tag → htmlTag (colored only)")
    func unknown() {
        let spans = SyntaxHighlighter.parse("a <span> b")
        let tag = spans.first { if case .htmlTag = $0.kind { return true }; return false }
        #expect(tag?.contentRange == NSRange(location: 3, length: 4))   // "span"
        #expect(!spans.contains { if case .htmlFormat = $0.kind { return true }; return false })
    }

    @Test("Unpaired whitelist tag → htmlTag, not htmlFormat")
    func unpaired() {
        let k = kinds("<u> alone")
        #expect(k.contains { if case .htmlTag = $0 { return true }; return false })
        #expect(!k.contains { if case .htmlFormat = $0 { return true }; return false })
    }

    @Test("Escaped `\\<u\\>` is not an HTML tag")
    func escaped() {
        let k = kinds("\\<u\\>")
        #expect(!k.contains { if case .htmlTag = $0 { return true }; return false })
        #expect(!k.contains { if case .htmlFormat = $0 { return true }; return false })
    }

    @Test("No HTML tag inside inline code")
    func insideCode() {
        let k = kinds("`<u>x</u>`")
        #expect(!k.contains { if case .htmlTag = $0 { return true }; return false })
        #expect(!k.contains { if case .htmlFormat = $0 { return true }; return false })
    }

    @Test("<!-- comment --> → .comment with <!-- / --> delimiters")
    func htmlComment() {
        let spans = SyntaxHighlighter.parse("a <!-- note --> b")
        let comment = spans.first { if case .comment = $0.kind { return true }; return false }
        #expect(comment != nil)
        #expect(comment?.fullRange == NSRange(location: 2, length: 13))
        #expect(comment?.delimiterRanges == [NSRange(location: 2, length: 4),    // <!--
                                             NSRange(location: 12, length: 3)])  // -->
    }

    @Test("A tag inside an HTML comment belongs to the comment, not the tag pass")
    func commentSwallowsTags() {
        let k = kinds("<!-- <u>x</u> -->")
        #expect(!k.contains { if case .htmlTag = $0 { return true }; return false })
        #expect(!k.contains { if case .htmlFormat = $0 { return true }; return false })
    }

    @Test("<img src> → image span carrying src and declared dimensions")
    func imgTag() {
        let text = "<img src=\"cat.png\" alt=\"a cat\" width=\"120\" height=\"80\">"
        let spans = SyntaxHighlighter.parse(text)
        let images = spans.filter { if case .image = $0.kind { return true }; return false }
        #expect(images.count == 1)
        guard let img = images.first else { return }
        if case .image(let dest, let w, let h) = img.kind {
            #expect(dest == "cat.png")
            #expect(w == 120)
            #expect(h == 80)
        }
        #expect(img.fullRange == NSRange(location: 0, length: (text as NSString).length))
        #expect((text as NSString).substring(with: img.contentRange) == "cat.png")
        #expect(!spans.contains { if case .htmlTag = $0.kind { return true }; return false })
    }

    @Test("<img> without dimensions parses with nil width/height")
    func imgNoDims() {
        let spans = SyntaxHighlighter.parse("<img src=\"cat.png\">")
        guard case .image(let dest, let w, let h)? =
            spans.first(where: { if case .image = $0.kind { return true }; return false })?.kind
        else { Issue.record("no image span"); return }
        #expect(dest == "cat.png")
        #expect(w == nil && h == nil)
    }

    @Test("<img> without a quoted src stays colored source (htmlTag)")
    func imgWithoutSrc() {
        let k = kinds("<img width=\"9\">")
        #expect(!k.contains { if case .image = $0 { return true }; return false })
        #expect(k.contains { if case .htmlTag = $0 { return true }; return false })
    }

    @Test("Hyphenated element name is a tag (§6.10)")
    func hyphenName() {
        let spans = SyntaxHighlighter.parse("a <my-element> b")
        let tag = spans.first { if case .htmlTag = $0.kind { return true }; return false }
        #expect(tag?.contentRange == NSRange(location: 3, length: 10))   // "my-element"
    }

    @Test("A quoted attribute value may contain `>`")
    func quotedGT() {
        let text = "<span title=\"a>b\">"
        let spans = SyntaxHighlighter.parse(text)
        let tags = spans.filter { if case .htmlTag = $0.kind { return true }; return false }
        #expect(tags.count == 1)
        #expect(tags.first?.fullRange == NSRange(location: 0, length: (text as NSString).length))
    }

    @Test("<img> accepts single-quoted and unquoted attribute values")
    func imgAltQuoting() {
        guard case .image(let dest1, _, _)? = SyntaxHighlighter.parse("<img src='cat.png'>")
            .first(where: { if case .image = $0.kind { return true }; return false })?.kind
        else { Issue.record("no image span for single-quoted src"); return }
        #expect(dest1 == "cat.png")

        guard case .image(let dest2, let w, _)? = SyntaxHighlighter.parse("<img src=cat.png width=120>")
            .first(where: { if case .image = $0.kind { return true }; return false })?.kind
        else { Issue.record("no image span for unquoted src"); return }
        #expect(dest2 == "cat.png")
        #expect(w == 120)
    }

    @Test("A closing tag with attributes is not a tag (§6.10)")
    func badCloseTag() {
        let k = kinds("</div class=\"x\">")
        #expect(!k.contains { if case .htmlTag = $0 { return true }; return false })
    }

    @Test("PI, declaration, and CDATA tokens become dimmed source")
    func otherRawHTML() {
        for text in ["x <?php echo ?> y", "x <!DOCTYPE html> y", "x <![CDATA[>&<]]> y"] {
            #expect(kinds(text).contains { if case .htmlTag = $0 { return true }; return false },
                    "no htmlTag span in \(text)")
        }
    }
}

@Suite("Rendering — HTML tags")
@MainActor
struct HTMLTagRenderingTests {

    private func attr(_ key: NSAttributedString.Key, at i: Int, in s: NSAttributedString) -> Any? {
        guard i < s.length else { return nil }
        return s.attribute(key, at: i, effectiveRange: nil)
    }

    @Test("Unknown tag: name red, brackets dimmed")
    func coloredSource() {
        let editor = makeEditor()
        let styled = editor.styleBlock("a <span> b")
        #expect(attr(.foregroundColor, at: 3, in: styled) as? NSColor == editor.theme.mathOperatorColor)
        #expect(isDimmed(at: 2, in: styled))   // <
        #expect(isDimmed(at: 7, in: styled))   // >
    }

    @Test("Inactive pair: tags hidden, content rendered")
    func pairInactive() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<u>hi</u>", cursorPosition: nil)
        #expect(isHidden(at: 0, in: styled))   // <u>
        #expect(isHidden(at: 5, in: styled))   // </u>
        #expect(attr(.underlineStyle, at: 3, in: styled) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("Active pair: tags shown (not hidden), content not underlined")
    func pairActive() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<u>hi</u>", cursorPosition: 4)
        #expect(!isHidden(at: 0, in: styled))
        #expect(attr(.underlineStyle, at: 3, in: styled) == nil)
    }

    @Test("kbd, mark, sub, sup map to their attributes")
    func attributeMap() {
        let editor = makeEditor()

        let kbd = editor.styleBlock("<kbd>K</kbd>", cursorPosition: nil)
        #expect((attr(.font, at: 5, in: kbd) as? NSFont) == editor.inlineCodeFont)
        #expect(attr(.backgroundColor, at: 5, in: kbd) as? NSColor == editor.inlineCodeBackground)

        let mark = editor.styleBlock("<mark>M</mark>", cursorPosition: nil)
        #expect(attr(.backgroundColor, at: 6, in: mark) != nil)

        let sub = editor.styleBlock("<sub>2</sub>", cursorPosition: nil)
        #expect((attr(.baselineOffset, at: 5, in: sub) as? CGFloat ?? 0) < 0)

        let sup = editor.styleBlock("<sup>2</sup>", cursorPosition: nil)
        #expect((attr(.baselineOffset, at: 5, in: sup) as? CGFloat ?? 0) > 0)

        let small = editor.styleBlock("<small>fine</small>", cursorPosition: nil)
        let f = attr(.font, at: 8, in: small) as? NSFont
        #expect(f != nil && f!.pointSize < editor.bodyFont.pointSize)
    }

    @Test("HTML comment: dimmed in edit view, hidden in reading view")
    func htmlComment() {
        let editor = makeEditor()
        let edit = editor.styleBlock("a <!-- note --> b", cursorPosition: nil)
        #expect(!isHidden(at: 5, in: edit))   // visible (dimmed) in edit mode

        let read = editor.styleBlock("a <!-- note --> b", cursorPosition: nil, hideComments: true)
        #expect(isHidden(at: 5, in: read))    // gone in reading view
    }

    @Test("Inner markdown still styles: <u>**b**</u>")
    func innerMarkdown() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<u>**b**</u>", cursorPosition: nil)
        // 'b' is at offset 5 (after <u> and **).
        #expect(attr(.underlineStyle, at: 5, in: styled) as? Int == NSUnderlineStyle.single.rawValue)
        let f = attr(.font, at: 5, in: styled) as? NSFont
        #expect(f != nil && NSFontManager.shared.traits(of: f!).contains(.boldFontMask))
    }

    @Test("An .htmlBlock renders as colored source: tags colored, markdown literal")
    func htmlBlockSource() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<div>\n**text**\n</div>", cursorPosition: nil)
        // "div" name colored like any recognized tag (offset 1).
        #expect(attr(.foregroundColor, at: 1, in: styled) as? NSColor == editor.theme.mathOperatorColor)
        // The `**` asterisks stay visible — raw HTML source, no markdown spans.
        #expect(!isHidden(at: 6, in: styled))
        #expect(!isHidden(at: 7, in: styled))
    }
}

@Suite("HTMLRenderer — whitelisted HTML passes through")
struct HTMLTagExportTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("Whitelisted tags render as real tags")
    func passesThrough() {
        #expect(html("<u>x</u>").contains("<u>x</u>"))
        #expect(html("<kbd>K</kbd>").contains("<kbd>K</kbd>"))
        #expect(html("<mark>m</mark>").contains("<mark>m</mark>"))
        #expect(html("H<sub>2</sub>O").contains("<sub>2</sub>"))
        #expect(html("x<sup>2</sup>").contains("<sup>2</sup>"))
        #expect(html("<small>fine</small>").contains("<small>fine</small>"))
    }

    @Test("Benign attributes kept, event handlers stripped")
    func hardensAttributes() {
        let out = html("<u class=\"x\" onclick=\"y\">hi</u>")
        #expect(out.contains("<u class=\"x\">hi</u>"))
        #expect(!out.contains("onclick"))
    }

    @Test("Inner markdown still renders inside a passed tag")
    func innerMarkdown() {
        #expect(html("<u>**b**</u>").contains("<u><strong>b</strong></u>"))
    }

    @Test("Non-whitelisted inline tag passes through raw (GFM)")
    func unknownPassesThrough() {
        let out = html("a <span>x</span> b")
        #expect(out.contains("<span>x</span>"))
    }

    @Test("A nested script inside a passed tag is tagfiltered")
    func nestedScriptTagfiltered() {
        let out = html("<u><script>alert(1)</script></u>")
        #expect(out.contains("<u>"))
        #expect(!out.contains("<script"))
        #expect(out.contains("&lt;script"))
    }
}

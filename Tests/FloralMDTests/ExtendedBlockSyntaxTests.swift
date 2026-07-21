// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
@testable import FloralMDCore

@Suite("Extended block Markdown")
struct ExtendedBlockSyntaxTests {
    @Test("Front matter is recognized only when closed at document start")
    func frontMatter() {
        let source = "---\ntitle: Note\ntags: [one]\n---\n# Body"
        let blocks = BlockParser.parse(source)
        #expect(blocks.first?.kind == .frontMatter)
        #expect(blocks.first?.content == "---\ntitle: Note\ntags: [one]\n---")
        #expect(BlockParser.parse("---\nunclosed").first?.kind == .thematicBreak)
        #expect(BlockParser.parse("text\n---\ntitle: no\n---")[1].kind != .frontMatter)
    }

    @Test("Read removes metadata while preserving original source-line anchors")
    func frontMatterReadMapping() {
        let html = HTMLRenderer.render(markdown: "---\ntitle: Note\n---\n# Body")
        #expect(!html.contains("title: Note"))
        #expect(html.contains("id=\"floralmd-l4\""))
        #expect(html.contains("Body"))
    }

    @Test("A multi-block comment is one parsing block and hidden in Read")
    func multiBlockComment() {
        let source = "before\n%%\nsecret **opaque**\nmore\n%%\nafter"
        let blocks = BlockParser.parse(source)
        #expect(blocks[1].kind == .multiBlockComment)
        #expect(blocks[1].content == "%%\nsecret **opaque**\nmore\n%%")
        let html = HTMLRenderer.render(markdown: source)
        #expect(!html.contains("secret"))
        #expect(html.contains("id=\"floralmd-l6\""))
    }

    @Test("GFM alerts remain enabled without Obsidian-only callouts")
    func calloutFamilies() {
        let gfmOnly = MarkdownFeatures.all.subtracting(.obsidianCallouts)
        #expect(Callout.isEnabled("note", features: gfmOnly))
        #expect(!Callout.isEnabled("abstract", features: gfmOnly))
        #expect(HTMLRenderer.render(
            markdown: "> [!note]\n> body", options: ReadRenderOptions(features: gfmOnly)
        ).contains("class=\"callout"))
        #expect(!HTMLRenderer.render(
            markdown: "> [!abstract]\n> body", options: ReadRenderOptions(features: gfmOnly)
        ).contains("class=\"callout"))
    }

    @Test("Collapsible callout markers are independently gated")
    func collapsibleCallout() {
        let source = "> [!note]- Folded\n> body"
        #expect(HTMLRenderer.render(markdown: source).contains("<details"))
        #expect(!HTMLRenderer.render(
            markdown: source,
            options: ReadRenderOptions(features: .all.subtracting(.collapsibleCallout))
        ).contains("<details"))
    }
}

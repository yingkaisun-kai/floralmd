// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit
import Testing
@testable import FloralMDCore

@Suite("Markdown feature model")
struct MarkdownFeaturesTests {
    private func contains(
        _ spans: [SyntaxHighlighter.Span],
        where predicate: (SyntaxHighlighter.Span.Kind) -> Bool
    ) -> Bool {
        spans.contains { predicate($0.kind) }
    }

    @Test("Every option is independent and included in the default set")
    func optionSetDefaults() {
        let features: [MarkdownFeatures] = [
            .highlight, .inlineComment, .callout, .wikilink, .footnote, .math,
            .frontMatter, .tag, .blockID, .imageDimensions, .wikilinkEmbed,
            .collapsibleCallout, .multiBlockComment, .obsidianCallouts,
        ]
        #expect(Set(features.map(\.rawValue)).count == features.count)
        #expect(features.allSatisfy { MarkdownFeatures.all.contains($0) })
    }

    @Test("Inline extension parsing falls back to literal source when disabled")
    func inlineParseGates() {
        #expect(contains(SyntaxHighlighter.parse("==hi==", features: .all)) { $0 == .highlight })
        #expect(!contains(SyntaxHighlighter.parse("==hi==", features: .all.subtracting(.highlight))) { $0 == .highlight })

        #expect(contains(SyntaxHighlighter.parse("%%note%%", features: .all)) { $0 == .comment })
        #expect(!contains(SyntaxHighlighter.parse("%%note%%", features: .all.subtracting(.inlineComment))) { $0 == .comment })

        let multiline = "%%\nsecret\n%%"
        #expect(contains(SyntaxHighlighter.parse(multiline, features: .all)) { $0 == .comment })
        #expect(!contains(SyntaxHighlighter.parse(
            multiline, features: .all.subtracting(.multiBlockComment)
        )) { $0 == .comment })

        #expect(contains(SyntaxHighlighter.parse("[[Note]]", features: .all)) {
            if case .wikilink = $0 { return true }
            return false
        })
        #expect(!contains(SyntaxHighlighter.parse("[[Note]]", features: .all.subtracting(.wikilink))) {
            if case .wikilink = $0 { return true }
            return false
        })

        #expect(contains(SyntaxHighlighter.parse("$x$", features: .all)) {
            if case .math = $0 { return true }
            return false
        })
        #expect(!contains(SyntaxHighlighter.parse("$x$", features: .all.subtracting(.math))) {
            if case .math = $0 { return true }
            return false
        })
    }

    @Test("Image dimensions are independently gated")
    func imageDimensionGate() {
        func dimensions(_ features: MarkdownFeatures) -> (Int?, Int?)? {
            for span in SyntaxHighlighter.parse("![alt|320x200](image.png)", features: features) {
                if case .image(_, let width, let height) = span.kind { return (width, height) }
            }
            return nil
        }
        #expect(dimensions(.all)?.0 == 320)
        #expect(dimensions(.all)?.1 == 200)
        #expect(dimensions(.all.subtracting(.imageDimensions))?.0 == nil)
        #expect(dimensions(.all.subtracting(.imageDimensions))?.1 == nil)
    }

    @Test("Read renderer uses the same inline feature gates")
    func readGates() {
        #expect(HTMLRenderer.render(markdown: "==hi==").contains("<mark>hi</mark>"))
        #expect(!HTMLRenderer.render(
            markdown: "==hi==",
            options: ReadRenderOptions(features: .all.subtracting(.highlight))
        ).contains("<mark>"))

        #expect(HTMLRenderer.render(markdown: "[[Note]]").contains("class=\"wikilink\""))
        #expect(!HTMLRenderer.render(
            markdown: "[[Note]]",
            options: ReadRenderOptions(features: .all.subtracting(.wikilink))
        ).contains("class=\"wikilink\""))
    }

    @MainActor
    @Test("Callout gate applies to Edit without changing raw storage")
    func editCalloutGate() {
        let editor = makeEditor()
        editor.loadContent("> [!note]\n> body")
        editor.markdownFeatures = .all.subtracting(.callout)
        let styled = editor.styleBlock("> [!note]\n> body")
        #expect(styled.attribute(.fragmentOverlay, at: 2, effectiveRange: nil) == nil)
        #expect(editor.string == editor.rawSource)
    }

    @MainActor
    @Test("Disabled syntax commands cannot insert unsupported source")
    func formattingCommandGate() {
        let editor = makeEditor()
        editor.loadContent("word")
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        editor.markdownFeatures = .all.subtracting([.highlight, .wikilink])
        editor.formatHighlight(nil)
        editor.formatWikilink(nil)
        #expect(editor.rawSource == "word")
    }
}

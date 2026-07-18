// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
@testable import FloralMDCore

// Cross-block reference-link resolution in the live editor. "use [foo] here" is
// block 0; the definition is block 2. Activating block 2 leaves block 0 styled,
// so its `[foo]` must resolve against a definition parsed from another block.
// 'f' of "foo" sits at offset 5.
@Suite("Integration — Reference links")
struct ReferenceLinkIntegrationTests {

    @Test("A shortcut reference resolves against a definition in another block")
    @MainActor func crossBlockResolves() {
        let editor = makeEditor()
        editor.loadContent("use [foo] here\n\n[foo]: https://e.com")
        activateBlock(2, in: editor)
        #expect(fgColor(at: 5, in: editor) == editor.linkColor)
    }

    @Test("With no matching definition the same text stays plain (not a link)")
    @MainActor func noDefinitionStaysPlain() {
        let editor = makeEditor()
        editor.loadContent("use [foo] here\n\nprose only")
        activateBlock(2, in: editor)
        #expect(fgColor(at: 5, in: editor) != editor.linkColor)
    }

    @Test("A definition inside a block quote resolves a use in another block")
    @MainActor func definitionInsideBlockQuoteResolves() {
        let editor = makeEditor()
        editor.loadContent("use [foo] here\n\n> [foo]: https://e.com")
        activateBlock(2, in: editor)
        #expect(fgColor(at: 5, in: editor) == editor.linkColor)
    }
}

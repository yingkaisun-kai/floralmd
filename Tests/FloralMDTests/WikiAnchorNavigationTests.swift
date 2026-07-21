// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit
import Testing
@testable import FloralMDCore

@MainActor
@Suite("Page-local wikilink navigation")
struct WikiAnchorNavigationTests {
    @Test("Heading target reports its original source line")
    func headingLine() {
        let editor = makeEditor()
        editor.loadContent("intro\n\n## Target\nbody")
        #expect(editor.sourceLine(forPageLocalWikiTarget: "#Target") == 3)
    }

    @Test("Block ID target reports the owning block's source line")
    func blockIDLine() {
        let editor = makeEditor()
        editor.loadContent("intro\n\nTarget paragraph ^stable-id\nafter")
        #expect(editor.sourceLine(forPageLocalWikiTarget: "#^stable-id") == 3)
    }

    @Test("Block ID navigation honors the feature gate")
    func blockIDGate() {
        let editor = makeEditor()
        editor.loadContent("Target ^stable-id")
        editor.markdownFeatures = .all.subtracting(.blockID)
        #expect(editor.sourceLine(forPageLocalWikiTarget: "#^stable-id") == nil)
    }

    @Test("A path-bearing target is not page-local")
    func crossFile() {
        let editor = makeEditor()
        editor.loadContent("# Target")
        #expect(editor.sourceLine(forPageLocalWikiTarget: "Other#Target") == nil)
    }
}

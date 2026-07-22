import AppKit
import Testing
@testable import FloralMDCore

@Suite("Terminal paragraph fragment transition")
struct TerminalParagraphTransitionTests {
    @MainActor
    private func makeWindowed(typewriter: Bool,
                              lineSpacing: CGFloat = 32) -> (EditorTextView, NSWindow) {
        let editor = makeEditor()
        var theme = EditorTheme.default
        theme.lineSpacing = lineSpacing
        theme.paragraphSpacingBefore = 2
        editor.applyTheme(theme, persist: false)
        editor.typewriterModeEnabled = typewriter

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll
        #expect(window.makeFirstResponder(editor))
        return (editor, window)
    }

    @Test("Physical Return updates the visible caret before the event returns",
          arguments: [CGFloat(4), CGFloat(32)])
    @MainActor
    func physicalReturnUpdatesIndicatorSynchronously(lineSpacing: CGFloat) throws {
        let (editor, window) = makeWindowed(typewriter: true, lineSpacing: lineSpacing)
        let document = (1...80).map { "Line \($0) body text." }.joined(separator: "\n")
        editor.loadContent(document)
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.setSelectedRange(NSRange(location: (document as NSString).length,
                                        length: 0))
        editor.scrollCursorToCenter()
        editor.updateFontHeightInsertionIndicator()
        let before = editor.fontHeightInsertionIndicator.frame

        try pressPhysicalReturn(in: window)

        let expected = try #require(editor.currentFontHeightInsertionPointFrame())
        let drawn = editor.fontHeightInsertionIndicator.frame
        #expect(abs(expected.minY - before.minY) > 10,
                "Return did not advance enough to exercise stale-caret flicker")
        #expect(abs(drawn.minY - expected.minY) < 1,
                "lineSpacing=\(lineSpacing): drawn \(drawn) vs expected \(expected)")
        #expect(abs(editor.reproTypewriterCenterDelta() ?? .greatestFiniteMagnitude) < 4)
        #expect(editor.rawSource == editor.string)
        _ = window
    }

    @MainActor
    private func pressPhysicalReturn(in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        window.sendEvent(event)
    }

    @Test("Physical Return terminal geometry survives the first real glyph",
          arguments: [false, true])
    @MainActor
    func physicalReturnMatchesFirstGlyph(typewriter: Bool) throws {
        let (editor, window) = makeWindowed(typewriter: typewriter)
        type("first line", into: editor)
        ensureFullLayout(editor)

        try pressPhysicalReturn(in: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)
        editor.updateFontHeightInsertionIndicator()
        let returnCaret = try #require(editor.currentFontHeightInsertionPointFrame())
        let returnDrawn = editor.fontHeightInsertionIndicator.frame
        type("x", into: editor)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)
        editor.updateFontHeightInsertionIndicator()
        let glyphCaret = try #require(editor.currentFontHeightInsertionPointFrame())

        #expect(abs(returnCaret.minY - glyphCaret.minY) < 1,
                "computed Return caret \(returnCaret) vs glyph \(glyphCaret)")
        #expect(abs(returnDrawn.minY - glyphCaret.minY) < 1,
                "drawn Return caret \(returnDrawn) vs glyph \(glyphCaret)")
        #expect(editor.rawSource == editor.string)
        _ = window
    }

    @Test("Physical Return in a document middle survives the first real glyph",
          arguments: [false, true])
    @MainActor
    func middleEmptyParagraphMatchesFirstGlyph(typewriter: Bool) throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let (editor, window) = makeWindowed(typewriter: typewriter)
            window.appearance = NSAppearance(named: appearanceName)
            editor.loadContent("first line\nafter")
            editor.setSelectedRange(NSRange(location: ("first line" as NSString).length,
                                            length: 0))
            ensureFullLayout(editor)

            try pressPhysicalReturn(in: window)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            ensureFullLayout(editor)
            editor.updateFontHeightInsertionIndicator()
            let returnCaret = try #require(editor.currentFontHeightInsertionPointFrame())
            let returnDrawn = editor.fontHeightInsertionIndicator.frame
            type("x", into: editor)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            ensureFullLayout(editor)
            editor.updateFontHeightInsertionIndicator()
            let glyphCaret = try #require(editor.currentFontHeightInsertionPointFrame())

            #expect(abs(returnCaret.minY - glyphCaret.minY) < 1,
                    "\(appearanceName): computed middle Return caret \(returnCaret) vs glyph \(glyphCaret)")
            #expect(abs(returnDrawn.minY - glyphCaret.minY) < 1,
                    "\(appearanceName): drawn middle Return caret \(returnDrawn) vs glyph \(glyphCaret)")
            #expect(editor.rawSource == editor.string)
            _ = window
        }
    }

    @Test("Heading, consecutive Return, and list exit keep the first glyph on the terminal line",
          arguments: ["heading", "consecutive", "list-exit"])
    @MainActor
    func structuredParagraphTransitions(_ scenario: String) throws {
        let (editor, window) = makeWindowed(typewriter: false)
        switch scenario {
        case "heading":
            type("# Heading", into: editor)
            try pressPhysicalReturn(in: window)
        case "consecutive":
            type("first line", into: editor)
            try pressPhysicalReturn(in: window)
            try pressPhysicalReturn(in: window)
        case "list-exit":
            type("- item", into: editor)
            try pressPhysicalReturn(in: window)
            try pressPhysicalReturn(in: window)
        default:
            Issue.record("unknown scenario")
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)
        editor.updateFontHeightInsertionIndicator()
        let returnCaret = try #require(editor.currentFontHeightInsertionPointFrame())
        type("x", into: editor)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)
        let glyphCaret = try #require(editor.currentFontHeightInsertionPointFrame())

        #expect(abs(returnCaret.minY - glyphCaret.minY) < 1,
                "\(scenario): Return \(returnCaret) vs glyph \(glyphCaret); source=\(editor.rawSource.debugDescription)")
        #expect(editor.rawSource == editor.string)
        _ = window
    }
}

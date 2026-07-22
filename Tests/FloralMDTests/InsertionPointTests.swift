import AppKit
import Testing
@testable import FloralMDCore

@Suite("Font-height insertion point")
struct InsertionPointTests {
    @MainActor
    private func tempImagePath() -> String {
        let image = NSImage(size: NSSize(width: 64, height: 48))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 48).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("caret-image-\(UUID().uuidString).png")
        try! data.write(to: url)
        return url.path
    }

    @Test("User spacing advances an empty paragraph without inflating its line box")
    @MainActor func insertionPointIgnoresLineSpacing() {
        let editor = makeEditor()
        var theme = EditorTheme.default
        theme.lineSpacing = 32
        editor.applyTheme(theme, persist: false)
        editor.loadContent("first line\n\nnext line")
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        ensureFullLayout(editor)

        let previousFrame = editor.lineRect(forCharacterAt: 10)
        let lineFrame = editor.lineRect(forCharacterAt: 11)
        let insertionFrame = editor.currentFontHeightInsertionPointFrame()
        let fontHeight = ceil(editor.bodyFont.ascender - editor.bodyFont.descender)

        #expect(previousFrame != nil)
        #expect(lineFrame != nil)
        #expect(insertionFrame != nil)
        #expect(abs((insertionFrame?.height ?? 0) - fontHeight) < 0.5)
        let expectedY = (previousFrame?.maxY ?? 0)
            + theme.lineSpacing + theme.paragraphSpacingBefore
        #expect(abs((lineFrame?.minY ?? 0) - expectedY) < 0.5)
        type("x", into: editor)
        ensureFullLayout(editor)
        let populatedLineFrame = editor.lineRect(forCharacterAt: 11)
        #expect(abs((lineFrame?.height ?? 0) - (populatedLineFrame?.height ?? 0)) < 0.5)
    }

    @Test("Terminal blank lines still use a font-height insertion point")
    @MainActor func terminalBlankLinesUseFontHeight() {
        let editor = makeEditor()
        var theme = EditorTheme.default
        theme.lineSpacing = 32
        editor.applyTheme(theme, persist: false)
        editor.loadContent("你好\n\n\n")
        editor.setSelectedRange(NSRange(location: editor.rawSource.utf16.count, length: 0))
        ensureFullLayout(editor)

        let proposed = NSRect(x: 42, y: 100, width: 2, height: 100)
        let insertionFrame = editor.fontHeightInsertionPointRect(from: proposed)
        let fontHeight = ceil(editor.bodyFont.ascender - editor.bodyFont.descender)

        #expect(abs(insertionFrame.height - fontHeight) < 0.5)
        #expect(insertionFrame.height < proposed.height)
        #expect(abs(insertionFrame.midY - proposed.midY) < 0.5)
    }

    @Test("Windowed terminal caret uses the explicit visible indicator")
    @MainActor func windowedTerminalCaretUsesVisibleIndicator() {
        let editor = makeEditor()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll

        editor.loadContent("test\n\n\n\n\n1111\n\n\n\n\n")
        editor.setSelectedRange(NSRange(location: editor.rawSource.utf16.count, length: 0))
        ensureFullLayout(editor)
        #expect(window.makeFirstResponder(editor))
        editor.updateFontHeightInsertionIndicator()

        let fontHeight = ceil(editor.bodyFont.ascender - editor.bodyFont.descender)
        #expect(editor.insertionPointColor == .clear)
        #expect(editor.fontHeightInsertionIndicator.superview === editor)
        #expect(editor.fontHeightInsertionIndicator.displayMode == .visible)
        #expect(abs(editor.fontHeightInsertionIndicator.frame.height - fontHeight) < 0.5)
        #expect(editor.insertionIndicatorBlinkTimer?.isValid == true)
    }

    @Test("Activating a rendered image line remeasures the blinking caret")
    @MainActor func imageActivationRemeasuresCaret() {
        let editor = makeEditor()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll
        #expect(window.makeFirstResponder(editor))

        let content = "before\n\n![preview](\(tempImagePath()))\n\nafter"
        editor.loadContent(content)
        editor.setSelectedRange(NSRange(location: (content as NSString).length, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)

        editor.setSelectedRange(NSRange(location: 8, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)
        editor.updateFontHeightInsertionIndicator()

        #expect(editor.rawSource == editor.string)
        #expect(editor.fontHeightInsertionIndicator.displayMode == .visible)
        #expect(abs(editor.reproInsertionIndicatorDelta() ?? .greatestFiniteMagnitude) <= 1)
    }

    @Test("Terminal caret after a rendered image uses the settled raw-line geometry")
    @MainActor func terminalCaretAfterImageUsesSettledGeometry() throws {
        let editor = makeEditor()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll
        #expect(window.makeFirstResponder(editor))

        let content = "before\n\n![preview](\(tempImagePath()))\n"
        editor.loadContent(content)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)

        editor.setSelectedRange(NSRange(location: (content as NSString).length, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)
        let emptyLineFrame = try #require(editor.currentFontHeightInsertionPointFrame())

        type("x", into: editor)
        ensureFullLayout(editor)
        editor.setSelectedRange(NSRange(location: editor.rawSource.utf16.count - 1, length: 0))
        let populatedLineFrame = try #require(editor.currentFontHeightInsertionPointFrame())

        #expect(abs(emptyLineFrame.minY - populatedLineFrame.minY) < 1,
                "Image-terminal caret was \(emptyLineFrame.minY - populatedLineFrame.minY)pt from the real line")
        #expect(editor.rawSource == editor.string)
    }

    @Test("Caret at image-only document end remains visible without a trailing newline")
    @MainActor func imageOnlyDocumentEndCaretIsVisible() throws {
        let editor = makeEditor()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll
        #expect(window.makeFirstResponder(editor))

        let content = "![preview|600](\(tempImagePath()))"
        editor.loadContent(content)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)

        editor.setSelectedRange(NSRange(location: (content as NSString).length, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)
        editor.updateFontHeightInsertionIndicator()

        let caret = try #require(editor.currentFontHeightInsertionPointFrame())
        #expect(caret.height == ceil(editor.bodyFont.ascender - editor.bodyFont.descender))
        #expect(scroll.contentView.bounds.intersects(caret))
        #expect(editor.fontHeightInsertionIndicator.displayMode == .visible)
    }

    @Test("Caret at plain-text document end remains visible without a trailing newline")
    @MainActor func plainTextDocumentEndCaretIsVisible() throws {
        let editor = makeEditor()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll
        #expect(window.makeFirstResponder(editor))

        let content = "前面的讨论。\n\n然后应该展示个表格，展示 tpt bench 的情况"
        #expect(!content.hasSuffix("\n"))
        editor.loadContent(content)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)

        editor.setSelectedRange(NSRange(location: (content as NSString).length, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ensureFullLayout(editor)
        editor.updateFontHeightInsertionIndicator()

        let caret = try #require(editor.fontHeightInsertionPointFrame())
        #expect(caret.height == ceil(editor.bodyFont.ascender - editor.bodyFont.descender))
        #expect(scroll.contentView.bounds.intersects(caret))
        #expect(editor.fontHeightInsertionIndicator.displayMode == .visible)
        #expect(editor.rawSource == editor.string)
    }

    @Test("Terminal empty-line caret keeps custom spacing before typing")
    @MainActor func terminalCaretKeepsCustomSpacingBeforeTyping() throws {
        let editor = makeEditor()
        var theme = EditorTheme.default
        theme.lineSpacing = 48
        theme.paragraphSpacingBefore = 72
        editor.applyTheme(theme, persist: false)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll
        #expect(window.makeFirstResponder(editor))

        editor.loadContent("你好\n\n这个\n\n还真是")
        editor.setSelectedRange(NSRange(location: editor.rawSource.utf16.count, length: 0))
        ensureFullLayout(editor)

        pressEnter(in: editor)
        ensureFullLayout(editor)
        let emptyLineFrame = try #require(editor.currentFontHeightInsertionPointFrame())

        type("字", into: editor)
        ensureFullLayout(editor)
        editor.setSelectedRange(NSRange(location: editor.rawSource.utf16.count - 1, length: 0))
        let populatedLineFrame = try #require(editor.currentFontHeightInsertionPointFrame())

        #expect(abs(emptyLineFrame.minY - populatedLineFrame.minY) < 1,
                "Return-only caret was \(populatedLineFrame.minY - emptyLineFrame.minY)pt above the real line")
        #expect(editor.rawSource == editor.string)
    }

    @Test("Synthetic terminal geometry wins when TextKit absorbs EOF into the prior fragment")
    @MainActor func terminalGeometryWinsOverAbsorbedEOFFragment() throws {
        let absorbedPriorFragment = NSRect(x: 20, y: 40, width: 2, height: 19)
        let syntheticTerminalLine = NSRect(x: 20, y: 96, width: 2, height: 19)

        let resolved = try #require(EditorTextView.preferredInsertionPointFrame(
            measured: absorbedPriorFragment,
            syntheticEmptyLine: syntheticTerminalLine
        ))

        #expect(resolved == syntheticTerminalLine)
    }

    @Test("One and consecutive trailing newlines include both custom spacing values",
          arguments: [1, 2])
    @MainActor func trailingNewlineGeometryIncludesCustomSpacing(_ newlineCount: Int) throws {
        let editor = makeEditor()
        var theme = EditorTheme.default
        theme.lineSpacing = 31
        theme.paragraphSpacingBefore = 17
        editor.applyTheme(theme, persist: false)

        let source = "first" + String(repeating: "\n", count: newlineCount)
        editor.loadContent(source)
        let end = (source as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        ensureFullLayout(editor)

        let previous = try #require(editor.lineRect(forCharacterAt: end - 1))
        let terminal = try #require(editor.lineRect(forCharacterAt: end))
        let caret = try #require(editor.currentFontHeightInsertionPointFrame())
        let expectedY = previous.maxY + theme.lineSpacing + theme.paragraphSpacingBefore

        #expect(abs(terminal.minY - expectedY) < 0.5)
        #expect(abs(caret.midY - terminal.midY) < 0.5)
        #expect(editor.rawSource == editor.string)
    }

    @Test("IME marked-text growth advances the explicit short caret at EOF")
    @MainActor func markedTextGrowthAdvancesCaretAtEOF() {
        let editor = makeEditor()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll

        editor.loadContent("prefix")
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        ensureFullLayout(editor)
        #expect(window.makeFirstResponder(editor))
        editor.updateFontHeightInsertionIndicator()

        editor.setMarkedText("gl'bn",
                             selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.updateFontHeightInsertionIndicator()

        #expect(editor.hasMarkedText())
        #expect(editor.rawSource == "prefix")
        #expect(editor.string == "prefixgl'bn")
        #expect(abs(editor.reproInsertionIndicatorDelta() ?? .greatestFiniteMagnitude) <= 1)

        // Moving inside the marked string (candidate edit / pinyin backtrack)
        // must move the short caret without committing provisional storage.
        editor.setMarkedText("gl'bn",
                             selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: editor.markedRange())
        editor.updateFontHeightInsertionIndicator()
        #expect(editor.selectedRange().location == 8)
        #expect(abs(editor.reproInsertionIndicatorDelta() ?? .greatestFiniteMagnitude) <= 1)

        editor.insertText("光标", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        #expect(editor.rawSource == "prefix光标")
        #expect(editor.rawSource == editor.string)
    }
}

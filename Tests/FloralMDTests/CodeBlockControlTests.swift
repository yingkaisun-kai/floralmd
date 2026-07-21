import AppKit
import Testing
@testable import FloralMDCore

@Suite("Edit-mode fenced code chrome")
struct CodeBlockControlTests {
    @Test("Presentation keeps raw code only and preserves active/inactive geometry")
    @MainActor func sourceBackedPresentationAndStableGeometry() throws {
        let editor = makeEditor()
        let markdown = "```swift\nlet value = 1\nprint(value)\n```"
        let inactive = editor.styleBlock(markdown)
        let active = editor.styleBlock(markdown, cursorPosition: 18)

        let presentation = try #require(inactive.attribute(
            .codeBlockPresentation, at: 0, effectiveRange: nil
        ) as? CodeBlockPresentation)
        #expect(presentation.code == "let value = 1\nprint(value)")
        #expect(!presentation.code.contains("```"))
        #expect(inactive.string == markdown)
        #expect(active.string == markdown)

        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let constraint = CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        #expect(inactive.boundingRect(with: constraint, options: options).height
                == active.boundingRect(with: constraint, options: options).height)

        let ns = markdown as NSString
        let middle = ns.range(of: "let value").location
        let closing = ns.range(of: "```", options: .backwards).location
        guard case .codeBlock(_, _, true, false)? =
                (blockDecoration(at: 0, in: inactive)?.kind) else {
            Issue.record("opening fence must start the code background boundary")
            return
        }
        guard case .codeBlock(_, _, false, false)? =
                (blockDecoration(at: middle, in: inactive)?.kind) else {
            Issue.record("code body must carry the tiled background")
            return
        }
        guard case .codeBlock(_, _, false, true)? =
                (blockDecoration(at: closing, in: inactive)?.kind) else {
            Issue.record("closing fence must end the code background boundary")
            return
        }
    }

    @Test("Language label truncates before the hover control and disappears when too narrow")
    func labelAndControlDoNotOverlap() throws {
        let rect = try #require(CodeBlockChromeLayout.languageLabelRect(
            blockLeft: 0,
            blockWidth: 180,
            textSize: CGSize(width: 260, height: 12)
        ))
        let controlMinX = 180 - CodeBlockChromeLayout.trailingInset
            - CodeBlockChromeLayout.controlWidth
        #expect(rect.maxX + CodeBlockChromeLayout.labelGap <= controlMinX)
        #expect(rect.maxX + CodeBlockChromeLayout.labelGap == controlMinX)
        #expect(rect.minX >= CodeBlockChromeLayout.labelLeadingInset)
        #expect(rect.minY == CodeBlockChromeLayout.labelTopInset)

        #expect(CodeBlockChromeLayout.languageLabelRect(
            blockLeft: 0,
            blockWidth: 90,
            textSize: CGSize(width: 260, height: 12)
        ) == nil)
    }

    @Test("Compact opening rows draw complete labels above TextKit fragments")
    @MainActor func compactLanguageLabelUsesForegroundOverlay() throws {
        let editor = makeEditor()
        editor.frame = CGRect(x: 0, y: 0, width: 500, height: 180)
        editor.codeBlockLanguageOverlayView.frame = editor.bounds
        editor.loadContent("```swift\nhello\n```\n\nafter")
        activateBlock(editor.blocks.count - 1, in: editor)
        ensureFullLayout(editor)

        let item = try #require(editor.codeBlockLanguageOverlayView.visibleItems().first)
        #expect(item.label == "Swift")
        #expect(item.frame.minY >= editor.textContainerOrigin.y)
        #expect(item.frame.height >= 19)
        #expect(item.frame.maxY > item.frame.minY)
    }

    @Test("Only the copy button captures mouse hits")
    @MainActor func controlHitTestingPassesTransparentAreaThrough() {
        let control = CodeBlockControlView(frame: CGRect(
            x: 0, y: 0,
            width: CodeBlockChromeLayout.controlWidth,
            height: CodeBlockChromeLayout.controlHeight
        ))
        control.show(frame: control.frame, strings: .english)

        #expect(control.hitTest(CGPoint(x: 4, y: control.bounds.midY)) == nil)
        #expect(control.hitTest(CGPoint(x: control.buttonRect.midX,
                                       y: control.buttonRect.midY)) === control)
    }

    @Test("Copy glyph is 14 points and centered in its button")
    func copyGlyphGeometry() {
        let button = CGRect(x: 42, y: 8,
                            width: CodeBlockChromeLayout.controlHeight,
                            height: CodeBlockChromeLayout.controlHeight)
        let rects = CodeBlockChromeLayout.copyIconRects(in: button)
        let bounds = rects.back.union(rects.front)

        #expect(bounds.width == 14)
        #expect(bounds.height == 14)
        #expect(bounds.midX == button.midX)
        #expect(bounds.midY == button.midY)
    }

    @Test("Hover hit testing includes right-side code background, not just glyphs")
    @MainActor func backgroundHitTesting() throws {
        let editor = makeEditor()
        editor.textContainerInset = CGSize(width: 20, height: 20)
        editor.loadContent("```swift\nlet value = 1\n```\n\nafter")
        activateBlock(editor.blocks.count - 1, in: editor)
        ensureFullLayout(editor)

        let tlm = try #require(editor.textLayoutManager)
        var decorated: DecoratedTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            guard let fragment = fragment as? DecoratedTextLayoutFragment,
                  fragment.codeBlockPresentation != nil else { return true }
            decorated = fragment
            return false
        }
        let fragment = try #require(decorated)
        let point = CGPoint(
            x: editor.textContainerOrigin.x + (tlm.textContainer?.size.width ?? 0) - 4,
            y: editor.textContainerOrigin.y + fragment.layoutFragmentFrame.midY
        )
        let hit = try #require(editor.codeBlockHit(at: point))
        #expect(hit.presentation.code == "let value = 1")
        #expect(hit.frame.contains(point))
    }

    @Test("Editor intercepts the visible button before NSTextView selection handling")
    @MainActor func editorMouseGate() {
        let editor = makeEditor()
        editor.loadContent("before\n```swift\nlet value = 1\n```")
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let pasteboard = NSPasteboard(name: .init("FloralMDTests.codeGate.\(UUID().uuidString)"))
        editor.codeBlockCopyPasteboard = pasteboard
        let presentation = CodeBlockPresentation(code: "let value = 1")
        editor.hoveredCodeBlock = CodeBlockHit(
            presentation: presentation,
            frame: CGRect(x: 20, y: 20, width: 300, height: 80),
            controlY: 21
        )
        let controlFrame = CGRect(x: 250, y: 21,
                                  width: CodeBlockChromeLayout.controlWidth,
                                  height: CodeBlockChromeLayout.controlHeight)
        editor.codeBlockControlView.show(frame: controlFrame, strings: .english)
        let selectionBefore = editor.selectedRange()

        #expect(!editor.handleCodeBlockControlClick(
            at: CGPoint(x: controlFrame.minX + 2, y: controlFrame.midY)
        ))
        #expect(editor.handleCodeBlockControlClick(
            at: CGPoint(x: controlFrame.maxX - 5, y: controlFrame.midY)
        ))
        #expect(pasteboard.string(forType: .string) == "let value = 1")
        #expect(editor.selectedRange() == selectionBefore)
    }

    @Test("Copy writes code, shows feedback, and preserves focus and selection")
    @MainActor func copyPreservesEditorInteractionState() throws {
        let editor = makeEditor()
        editor.loadContent("```swift\nlet value = 1\n```\n\nafter")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 4))

        let pasteboard = NSPasteboard(name: .init("FloralMDTests.codeCopy.\(UUID().uuidString)"))
        editor.codeBlockCopyPasteboard = pasteboard
        editor.codeBlockCopyStrings = ReadModeCopyStrings(
            copyCode: "复制代码", copied: "已复制", announcement: "代码已复制"
        )
        let presentation = CodeBlockPresentation(code: "let value = 1")
        let selectionBefore = editor.selectedRange()
        let responderBefore = window.firstResponder

        editor.copyCodeBlock(presentation)

        #expect(pasteboard.string(forType: .string) == "let value = 1")
        #expect(editor.selectedRange() == selectionBefore)
        #expect(window.firstResponder === responderBefore)
        #expect(window.firstResponder === editor)
        #expect(editor.codeBlockControlView.isShowingFeedback)
        #expect(editor.codeBlockControlView.accessibilityLabel() == "已复制")
    }

    @Test("Active blocks move the control off a long raw info string")
    @MainActor func activeRawFenceAvoidsControlOverlap() throws {
        let editor = makeEditor()
        editor.textContainerInset = CGSize(width: 20, height: 20)
        let language = String(repeating: "very-long-language-name-", count: 5)
        editor.loadContent("```\(language)\nshort code\n```\n\nafter")
        activateBlock(0, in: editor)
        ensureFullLayout(editor)

        let tlm = try #require(editor.textLayoutManager)
        var firstFragment: DecoratedTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            guard let fragment = fragment as? DecoratedTextLayoutFragment,
                  fragment.codeBlockPresentation?.isActive == true else { return true }
            firstFragment = fragment
            return false
        }
        let first = try #require(firstFragment)
        let point = CGPoint(
            x: editor.textContainerOrigin.x + (tlm.textContainer?.size.width ?? 0) - 4,
            y: editor.textContainerOrigin.y + first.layoutFragmentFrame.midY
        )
        let hit = try #require(editor.codeBlockHit(at: point))
        #expect(hit.controlY > hit.frame.minY + 1,
                "the active raw info string owns the opening row")
    }
}

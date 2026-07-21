// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
@testable import FloralMDCore

@Suite("Editor link interactions", .serialized)
@MainActor
struct EditorLinkInteractionTests {
    private func laidOutPoint(at character: Int,
                              in editor: EditorTextView) -> NSPoint?
    {
        guard let tlm = editor.textLayoutManager,
              let location = tlm.location(tlm.documentRange.location, offsetBy: character),
              let fragment = tlm.textLayoutFragment(for: location),
              let paragraphStart = fragment.textElement?.elementRange?.location else { return nil }
        let offset = tlm.offset(from: paragraphStart, to: location)
        guard let line = fragment.textLineFragments.first(where: {
            offset >= $0.characterRange.location && offset < NSMaxRange($0.characterRange)
        }) else { return nil }
        return NSPoint(
            x: editor.textContainerOrigin.x + fragment.layoutFragmentFrame.minX
                + line.typographicBounds.minX + line.locationForCharacter(at: offset).x + 1,
            y: editor.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
                + line.typographicBounds.midY
        )
    }

    @Test("Link hint view uses injected localized copy")
    func localizedHint() {
        let editor = makeEditor()
        #expect(editor.linkHoverHintView.label.stringValue.isEmpty)

        editor.linkNavigationHint = "按住 Command 点击跳转"
        #expect(editor.linkHoverHintView.label.stringValue == "按住 Command 点击跳转")
    }

    @Test("Hover stays I-beam while Command press and release switch immediately")
    func commandCursorLifecycle() {
        let source = "# Target\n\n[Jump](#Target)\n\nEnd"
        let editor = makeEditor()
        editor.loadContent(source)
        let link = (source as NSString).range(of: "Jump")
        let linkRect = NSRect(x: 40, y: 40, width: 80, height: 24)
        let linkPoint = linkRect.center

        editor.hoveredLinkHit = .init(range: link, cursorRect: linkRect)
        editor.setAccessibilityHelp(editor.linkNavigationHint)
        #expect(editor.hoveredLinkHit?.range == link)
        #expect(editor.pointerCursorKind(at: linkPoint, modifiers: []) == .iBeam)
        #expect(editor.accessibilityHelp() == editor.linkNavigationHint)

        editor.showLinkHoverHint(ifExpectedRange: link)
        #expect(!editor.linkHoverHintView.isHidden)
        #expect(editor.linkHoverHintView.label.stringValue == editor.linkNavigationHint)

        #expect(editor.pointerCursorKind(at: linkPoint, modifiers: .command) == .pointingHand)
        #expect(editor.pointerCursorKind(at: linkPoint, modifiers: []) == .iBeam)

    }

    @Test("Plain click has no navigation action while Command-click follows the existing anchor route")
    func clickSemantics() {
        let source = "# Target\n\n[Jump](#Target)\n\nEnd"
        let link = (source as NSString).range(of: "Jump")
        let editor = makeEditor()
        editor.loadContent(source)
        #expect(editor.linkNavigationAction(atCharacterIndex: link.location,
                                            modifiers: []) == nil)
        #expect(editor.linkNavigationAction(atCharacterIndex: link.location,
                                            modifiers: .command) == .regular("#Target"))

        let wikiSource = "Paragraph ^stable\n\n[[#^stable|Block]]"
        editor.loadContent(wikiSource)
        let wikiLink = (wikiSource as NSString).range(of: "Block")
        #expect(editor.linkNavigationAction(atCharacterIndex: wikiLink.location,
                                            modifiers: []) == nil)
        #expect(editor.linkNavigationAction(atCharacterIndex: wikiLink.location,
                                            modifiers: .command) == .wiki("#^stable"))
    }

    @Test("A wrapped link remains hittable on each laid-out line segment")
    func wrappedLinkHit() throws {
        let source = "# Target\n\n[alpha beta gamma delta epsilon zeta eta theta](#Target)\n\nEnd"
        let editor = makeEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 210, height: 500)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.textContainer?.containerSize = NSSize(
            width: 210,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.loadContent(source)
        ensureFullLayout(editor)
        let ns = source as NSString
        let link = ns.range(of: "alpha beta gamma delta epsilon zeta eta theta")

        let firstPoint = try #require(laidOutPoint(at: link.location, in: editor))
        let lastPoint = try #require(laidOutPoint(at: link.upperBound - 2, in: editor))
        let first = editor.linkHoverHit(at: firstPoint)
        let last = editor.linkHoverHit(at: lastPoint)

        #expect(first?.range == link)
        #expect(last?.range == link)
        #expect(first?.cursorRect.minY != last?.cursorRect.minY)
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

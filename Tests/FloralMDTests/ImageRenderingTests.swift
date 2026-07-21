// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
@testable import FloralMDCore

@Suite("Image rendering")
@MainActor
struct ImageRenderingTests {

    /// Writes a tiny solid PNG to a temp file and returns its absolute path
    /// (absolute so resolution doesn't need a document directory).
    private func tempPNGPath() -> String {
        let size = NSSize(width: 24, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-img-test-\(UUID().uuidString).png")
        try! data.write(to: url)
        return url.path
    }

    @Test("Image syntax parses to an image span carrying the destination")
    func parsesImage() {
        let dests = SyntaxHighlighter.parse("![alt](pic.png)").compactMap { s -> String? in
            if case .image(let d, _, _) = s.kind { return d }; return nil
        }
        #expect(dests == ["pic.png"])
    }

    @Test("Obsidian image-size suffix controls overlay width")
    func obsidianWidthSuffix() {
        let editor = makeEditor()
        let path = tempPNGPath()
        let styled = editor.styleBlock("![alt|12](\(path))", cursorPosition: nil)
        let overlay = styled.attribute(.fragmentOverlay, at: 0,
                                       effectiveRange: nil) as? FragmentOverlay
        #expect(overlay?.bounds.size == CGSize(width: 12, height: 8))
    }

    @Test("Resize drag updates the foreground preview without changing TextKit bounds")
    func resizeDragUsesForegroundPreview() {
        let editor = makeEditor()
        editor.loadContent("![preview](image.png)")
        let image = NSImage(size: NSSize(width: 80, height: 60))
        let overlay = FragmentOverlay(
            image: image,
            bounds: NSRect(x: 0, y: 0, width: 80, height: 60),
            role: .resizableImage
        )

        let oldFrame = NSRect(x: 10, y: 10, width: 80, height: 60)
        let hit = ImageOverlayHit(anchor: 0, sourceRange: NSRange(location: 0, length: 21),
                                  frame: oldFrame, overlay: overlay)
        editor.imageResizeSession = ImageResizeSession(
            hit: hit,
            startPoint: .zero,
            selectionBefore: NSRange(location: 0, length: 0),
            previewFrame: oldFrame
        )
        for step in 1...30 {
            #expect(editor.updateImageResize(to: CGPoint(x: -CGFloat(step), y: 0)))
            #expect(editor.imageResizeSession?.previewFrame.width == 80 - CGFloat(step))
            #expect(editor.imageResizeChromeView.frame.width == 84 - CGFloat(step))
        }

        #expect(overlay.bounds.size == CGSize(width: 80, height: 60))
        #expect(editor.imageResizeSession?.previewFrame
                == NSRect(x: 10, y: 10, width: 50, height: 37.5))
        #expect(editor.imageResizeChromeView.frame
                == NSRect(x: 8, y: 8, width: 54, height: 41.5))
        #expect(!editor.imageResizeChromeView.isHidden)
        #expect(editor.rawSource == "![preview](image.png)")
    }

    @Test("Suppressing the fragment image leaves no stored-size duplicate")
    func suppressedFragmentImageHasNoDuplicate() throws {
        let editor = makeEditor()
        let content = "![preview](\(tempPNGPath()))\n\nafter"
        editor.loadContent(content)
        editor.setSelectedRange(NSRange(location: (content as NSString).length, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll
        ensureFullLayout(editor)

        let tlm = try #require(editor.textLayoutManager)
        let location = try #require(tlm.location(tlm.documentRange.location, offsetBy: 0))
        let fragment = try #require(tlm.textLayoutFragment(for: location)
                                    as? DecoratedTextLayoutFragment)
        let pair = try #require(fragment.overlays.first(where: {
            $0.overlay.role == .resizableImage
        }))
        pair.overlay.suppressesImageDrawing = true
        editor.needsDisplay = true
        let hiddenRep = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: hiddenRep)
        pair.overlay.suppressesImageDrawing = false
        var hiddenBluePixels = 0
        for y in 0 ..< hiddenRep.pixelsHigh {
            for x in 0 ..< hiddenRep.pixelsWide {
                guard let color = hiddenRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.blueComponent > 0.7,
                      color.redComponent < 0.35,
                      color.greenComponent < 0.75 else { continue }
                hiddenBluePixels += 1
            }
        }
        #expect(hiddenBluePixels == 0,
                "Stored-size fragment image remained under the resize preview")
        #expect(editor.rawSource == content)
    }

    @Test("Resize chrome is a topmost pass-through view that follows its image frame")
    func resizeChromeViewFollowsImageFrame() throws {
        let chrome = ImageResizeChromeView(frame: .zero)
        let first = NSRect(x: 30, y: 40, width: 120, height: 80)
        chrome.show(around: first, accentColor: .systemRed,
                    backgroundColor: .white, isResizing: false)

        #expect(chrome.frame == first.insetBy(dx: -2, dy: -2))
        #expect(!chrome.isHidden)
        #expect(chrome.hitTest(NSPoint(x: 20, y: 20)) == nil)

        let resized = NSRect(x: 30, y: 40, width: 210, height: 140)
        let previewImage = try #require(NSImage(contentsOfFile: tempPNGPath()))
        chrome.show(around: resized, image: previewImage, accentColor: .systemRed,
                    backgroundColor: .white, isResizing: true)
        #expect(chrome.frame == resized.insetBy(dx: -2, dy: -2))

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            chrome.appearance = NSAppearance(named: appearanceName)
            chrome.needsDisplay = true
            let rep = try #require(chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds))
            chrome.cacheDisplay(in: chrome.bounds, to: rep)
            var redPixels = 0
            var bluePixels = 0
            for y in 0 ..< rep.pixelsHigh {
                for x in 0 ..< rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    else { continue }
                    if color.redComponent > 0.55,
                       color.greenComponent < 0.55,
                       color.blueComponent < 0.55 {
                        redPixels += 1
                    }
                    if color.blueComponent > 0.7,
                       color.redComponent < 0.35,
                       color.greenComponent < 0.75 {
                        bluePixels += 1
                    }
                }
            }
            #expect(redPixels > 100,
                    "Resize chrome was not visible in \(appearanceName.rawValue)")
            #expect(bluePixels > 1_000,
                    "Resize image preview was not visible in \(appearanceName.rawValue)")
        }

        chrome.hide()
        #expect(chrome.isHidden)
    }

    @Test("Image hover hit-testing covers the visible image above its text fragment")
    func hoverHitTestingUsesImageBounds() throws {
        let editor = makeEditor()
        let content = "before\n\n![preview|200](\(tempPNGPath()))\n\nafter"
        editor.loadContent(content)
        editor.setSelectedRange(NSRange(location: (content as NSString).length, length: 0))
        ensureFullLayout(editor)

        let tlm = try #require(editor.textLayoutManager)
        let imageOffset = (content as NSString).range(of: "![preview").location
        let location = try #require(tlm.location(tlm.documentRange.location,
                                                 offsetBy: imageOffset))
        let fragment = try #require(tlm.textLayoutFragment(for: location)
                                    as? DecoratedTextLayoutFragment)
        let pair = try #require(fragment.overlays.first(where: {
            $0.overlay.role == .resizableImage
        }))
        let localRect = try #require(fragment.overlayRect(anchorOffset: pair.offset,
                                                          overlay: pair.overlay))
        let imageFrame = localRect.offsetBy(
            dx: fragment.layoutFragmentFrame.minX + editor.textContainerOrigin.x,
            dy: fragment.layoutFragmentFrame.minY + editor.textContainerOrigin.y
        )
        let hit = editor.imageOverlayHit(at: CGPoint(x: imageFrame.midX,
                                                     y: imageFrame.minY + 4))

        #expect(hit?.overlay === pair.overlay)
        #expect(hit?.frame == imageFrame)
    }

    @Test("Rendered image draws an overlay and hides the raw markdown")
    func rendersOverlay() {
        let editor = makeEditor()
        let styled = editor.styleBlock("![alt](\(tempPNGPath()))", cursorPosition: nil)
        // Overlay anchored on the leading `!`.
        let overlay = styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
        #expect(overlay != nil)
        // The rest of the markdown is hidden (near-zero font).
        let f = styled.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        #expect((f?.pointSize ?? 99) < 1.0)
    }

    @Test("Active image shows the raw markdown (no overlay)")
    func activeShowsRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("![alt](\(tempPNGPath()))", cursorPosition: 3)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
    }

    @Test("HTML <img> renders an overlay and hides the raw tag")
    func htmlImgRendersOverlay() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<img src=\"\(tempPNGPath())\">", cursorPosition: nil)
        // Overlay anchored on the leading `<`.
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) != nil)
        let f = styled.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        #expect((f?.pointSize ?? 99) < 1.0)
    }

    @Test("Active HTML <img> shows the raw tag (no overlay)")
    func htmlImgActiveShowsRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<img src=\"\(tempPNGPath())\">", cursorPosition: 3)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Declared width/height size the overlay exactly; one alone scales proportionally")
    func declaredDimensions() {
        let editor = makeEditor()
        let path = tempPNGPath()   // natural 24×16

        let exact = editor.imageOverlay(destination: path, width: 12, height: 10)
        #expect(exact?.bounds.size == CGSize(width: 12, height: 10))

        let widthOnly = editor.imageOverlay(destination: path, width: 12)
        #expect(widthOnly?.bounds.size == CGSize(width: 12, height: 8))

        let heightOnly = editor.imageOverlay(destination: path, height: 8)
        #expect(heightOnly?.bounds.size == CGSize(width: 12, height: 8))

        let natural = editor.imageOverlay(destination: path)
        #expect(natural?.bounds.size == CGSize(width: 24, height: 16))
    }

    @Test("Missing local image shows a blocked-image placeholder overlay, not just alt text")
    func fallbackShowsPlaceholder() {
        let editor = makeEditor()
        let styled = editor.styleBlock("![alt](/no/such/file.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) != nil)
        guard case .blocked(.notFound) = editor.imageDisplay(destination: "/no/such/file.png") else {
            Issue.record("expected .blocked(.notFound)"); return
        }
    }

    @Test("A path that resolves but isn't image data is classified as 'not an image'")
    func notAnImage() {
        let editor = makeEditor()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-not-image-\(UUID().uuidString).png")
        try! Data("not a png".utf8).write(to: url)
        guard case .blocked(.notAnImage) = editor.imageDisplay(destination: url.path) else {
            Issue.record("expected .blocked(.notAnImage)"); return
        }
    }

    @Test("Plain-http image always shows the placeholder, even with remote images allowed")
    func httpImageAlwaysBlocked() {
        let editor = makeEditor()
        editor.allowRemoteImages = true
        let styled = editor.styleBlock("![alt](http://example.com/x.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) != nil)
        guard case .blocked(.httpUnsupported) = editor.imageDisplay(destination: "http://example.com/x.png") else {
            Issue.record("expected .blocked(.httpUnsupported)"); return
        }
    }

    @Test("Https image shows the placeholder while remote images are disallowed")
    func httpsImageBlockedByDefault() {
        let editor = makeEditor()
        editor.allowRemoteImages = false
        let styled = editor.styleBlock("![alt](https://example.com/x.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) != nil)
        guard case .blocked(.blockedBySetting) = editor.imageDisplay(destination: "https://example.com/x.png") else {
            Issue.record("expected .blocked(.blockedBySetting)"); return
        }
    }

    @Test("Https image is pending (no placeholder yet) while the fetch is in flight")
    func httpsImagePendingWhileFetching() {
        let editor = makeEditor()
        editor.allowRemoteImages = true
        // `.invalid` is RFC 2606-reserved (never resolves) — the request
        // fails async, off the assertion below; only the synchronous
        // first-call return value (.pending, before any response) matters.
        let dest = "https://example.invalid/pending-\(UUID().uuidString).png"
        guard case .pending = editor.imageDisplay(destination: dest) else {
            Issue.record("expected .pending"); return
        }
    }

    @Test("Narrowing the max-content-width column shrinks an already-rendered image")
    func shrinksOnColumnNarrow() {
        let editor = EditorTextView.makeTextKit2(
            frame: NSRect(x: 0, y: 0, width: 800, height: 300),
            containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        let suite = "FloralMDTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        editor.themeDefaults = defaults
        editor.theme = .load(from: defaults)

        let content = "![alt](\(tempPNGPath()))\n\nsecond paragraph" // image is 24x16, well under 800pt
        editor.loadContent(content)
        // `loadContent` puts the cursor at offset 0, inside the image block,
        // which renders raw markdown (no overlay) while active. Move the
        // cursor to the second block so the image renders as an overlay.
        editor.recomposeIncremental(cursorInRaw: content.count)
        let before = editor.textStorage?.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
        #expect(before?.bounds.width == 24)

        // Cap the column narrower than the image's natural width.
        editor.maxContentWidthPoints = 22

        let after = editor.textStorage?.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
        #expect((after?.bounds.width ?? 9999) <= editor.availableContentWidth + 0.01)
        #expect(after!.bounds.width < before!.bounds.width)
        // Aspect ratio preserved (24x16 -> half width -> half height).
        #expect(abs(after!.bounds.height / after!.bounds.width - 16.0 / 24.0) < 0.01)
    }
}

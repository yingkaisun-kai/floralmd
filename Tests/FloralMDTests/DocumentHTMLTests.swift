// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
@testable import FloralMDCore

@Suite("DocumentHTML — assembly & asset inlining")
@MainActor
struct DocumentHTMLTests {

    private func doc(_ md: String, dark: Bool = false) -> String {
        DocumentHTML.full(markdown: md, theme: .default,
                          callouts: Callout.defaultStyles, dark: dark)
    }

    @Test("Wraps body in a full self-contained document")
    func wrapper() {
        let out = doc("# Hi")
        #expect(out.hasPrefix("<!DOCTYPE html>"))
        #expect(out.contains("<style>"))
        #expect(out.contains("<div class=\"page\"><h1 id=\"floralmd-l1\">Hi</h1></div>"))
    }

    @Test("Copy controls are opt-in for the interactive Read WebView")
    func readModeCopyControlsAreOptIn() {
        let markdown = "```swift\nlet x = 1\n```"
        #expect(!doc(markdown).contains("href=\"x-floralmd-copy:"))

        let interactive = DocumentHTML.full(
            markdown: markdown,
            theme: .default,
            callouts: Callout.defaultStyles,
            dark: false,
            readModeCopyStrings: .english
        )
        #expect(interactive.contains("href=\"x-floralmd-copy:"))
        #expect(interactive.contains("Copy code"))
        #expect(interactive.contains("script-src 'none'"))
    }

    @Test("Can leave the Read page background transparent without changing the default")
    func transparentBackground() {
        let transparent = DocumentHTML.full(
            markdown: "# Hi",
            theme: .default,
            callouts: Callout.defaultStyles,
            dark: false,
            transparentBackground: true
        )
        #expect(transparent.contains("--bg: transparent;"))
        #expect(doc("# Hi").contains("--bg: #ffffff;"))
    }

    @Test("Callout icon is an inline (vector) Lucide SVG, not a rasterized SF Symbol")
    func calloutIcon() {
        let out = doc("> [!note]\n> body")
        #expect(out.contains("<span class=\"callout-icon\"><svg"))
        #expect(out.contains("stroke=\"currentColor\""))   // tinted by CSS, not baked
        // No leftover SF-Symbol asset pass: no placeholder, no PNG icon.
        #expect(!out.contains("data-symbol"))
        #expect(!out.contains("<span class=\"callout-icon\"><img"))
    }

    @Test("Read-mode checkboxes are inline Lucide SVGs (no SF Symbol, no PNG)")
    func checkboxIcons() {
        let out = doc("- [x] done\n- [ ] todo")
        #expect(out.contains("<span class=\"task-check task-check--checked\"><svg"))
        #expect(out.contains("<span class=\"task-check task-check--unchecked\"><svg"))
        #expect(!out.contains("type=\"checkbox\""))
        // The whole document ships no rasterized icon glyphs (math may still PNG).
        #expect(!out.contains("<span class=\"callout-icon\"><img"))
    }

    @Test("Inline math placeholder becomes an inlined image with baseline align")
    func inlineMath() {
        let out = doc("value $x^2$ here")
        #expect(!out.contains("data-tex"))
        #expect(out.contains("<img class=\"math math-inline\""))
        #expect(out.contains("vertical-align:"))
        #expect(out.contains("src=\"data:image/png;base64,"))
    }

    @Test("Display math placeholder becomes a centered image")
    func displayMath() {
        let out = doc("$$\nx^2\n$$")
        #expect(out.contains("class=\"math-display\"><img class=\"math\""))
        #expect(out.contains("id=\"floralmd-l1\""))
        #expect(out.contains("src=\"data:image/png;base64,"))
    }

    @Test("Display-mode math amid prose becomes a baseline-aligned image")
    func displayMathAmidProse() {
        let out = doc("before $$\\int_0^1 x$$ after")
        #expect(!out.contains("data-tex"))
        #expect(out.contains("<img class=\"math math-inline\""))
        #expect(out.contains("vertical-align:"))
        #expect(out.contains("before"))
        #expect(out.contains("after"))
    }

    @Test("Math can remain readable without loading SwiftMath resources")
    func mathSourceMode() {
        let out = DocumentHTML.full(
            markdown: "inline $x^2$ and $$z^2$$\n\n$$\ny = mx + b\n$$",
            theme: .default,
            callouts: Callout.defaultStyles,
            dark: false,
            renderMath: false
        )
        #expect(!out.contains("data-tex"))
        #expect(!out.contains("data:image/png"))
        #expect(out.contains("<code>x^2</code>"))
        #expect(out.contains("<code>z^2</code>"))
        #expect(out.contains("class=\"math-display\"><code>"))
        #expect(out.contains("y = mx + b"))
    }

    @Test("Unparseable math falls back to showing the source")
    func mathFallback() {
        let out = doc("bad $\\frac{$ math")
        #expect(out.contains("<code>\\frac{</code>"))
    }

    // End-to-end regression for the read-mode environment bug: with intact `\\`
    // row separators, SwiftMath renders the environment to an image instead of
    // the corrupted-latex `<code>` fallback.
    @Test("Display environment renders to an image, not the source fallback")
    func displayEnvironmentRenders() {
        let out = doc("$$\n\\begin{aligned} \\pi &= 3 \\\\ e &= 2 \\end{aligned}\n$$")
        #expect(out.contains("class=\"math-display\"><img class=\"math\""))
        #expect(!out.contains("<code>"))
    }

    @Test("Inline environment renders to an image, not the source fallback")
    func inlineEnvironmentRenders() {
        let out = doc("m $\\begin{cases} 1 & i=j \\\\ 0 & i\\neq j \\end{cases}$ ok")
        #expect(out.contains("<img class=\"math math-inline\""))
        #expect(!out.contains("<code>"))
    }

    // MARK: Images

    /// A tiny but fully valid, decodable PNG (a solid-color square) — real
    /// image bytes are required now that `imageDataURI` decodes to catch
    /// undecodable files (see `undecodableLocalImage`), not just the magic
    /// header bytes this used to get away with.
    private func validPNGData() -> Data {
        let size = NSSize(width: 4, height: 4)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test("Local image is read and inlined as a data URI")
    func localImageInlined() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floralmd-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try validPNGData().write(to: dir.appendingPathComponent("pic.png"))

        let out = DocumentHTML.full(markdown: "![cat](pic.png)", theme: .default,
                                    callouts: Callout.defaultStyles, dark: false,
                                    baseURL: dir)
        #expect(!out.contains("data-src"))   // placeholder consumed
        #expect(out.contains("<img class=\"md-image\" src=\"data:image/png;base64,"))
        #expect(out.contains("alt=\"cat\""))
    }

    @Test("Declared <img> width/height survive the asset pass")
    func imgDimensionsSurvive() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floralmd-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try validPNGData().write(to: dir.appendingPathComponent("pic.png"))

        let out = DocumentHTML.full(
            markdown: "<img src=\"pic.png\" alt=\"cat\" width=\"120\" height=\"80\">",
            theme: .default, callouts: Callout.defaultStyles, dark: false, baseURL: dir)
        #expect(!out.contains("data-src"))
        #expect(out.contains("src=\"data:image/png;base64,"))
        #expect(out.contains("width=\"120\" height=\"80\">"))
    }

    @Test("Unresolvable local image shows the blocked-image placeholder with 'Image not found'")
    func missingImage() {
        let out = doc("![gone](nope.png)")   // no baseURL → can't resolve
        #expect(out.contains("md-image-blocked"))
        #expect(out.contains("Image not found"))
        #expect(!out.contains("src="))
    }

    @Test("An existing-but-undecodable local file shows 'Not an image'")
    func undecodableLocalImage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floralmd-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a png".utf8).write(to: dir.appendingPathComponent("bad.png"))

        let out = DocumentHTML.full(markdown: "![bad](bad.png)", theme: .default,
                                    callouts: Callout.defaultStyles, dark: false,
                                    baseURL: dir)
        #expect(out.contains("md-image-blocked"))
        #expect(out.contains("Not an image"))
    }

    @Test("Remote image is suppressed by default, emitted when opted in")
    func remoteImagePolicy() {
        let md = "![r](https://example.com/x.png)"
        let off = DocumentHTML.full(markdown: md, theme: .default,
                                    callouts: Callout.defaultStyles, dark: false)
        #expect(off.contains("md-image-blocked"))
        #expect(off.contains("External images blocked"))
        #expect(!off.contains("https://example.com/x.png"))

        let on = DocumentHTML.full(markdown: md, theme: .default,
                                   callouts: Callout.defaultStyles, dark: false,
                                   options: ReadRenderOptions(allowRemoteImages: true))
        #expect(on.contains("src=\"https://example.com/x.png\""))
    }

    @Test("Plain-http image always shows the blocked-image placeholder, even opted in")
    func httpImageAlwaysBlocked() {
        let md = "![r](http://example.com/x.png)"
        for allow in [false, true] {
            let out = DocumentHTML.full(markdown: md, theme: .default,
                                        callouts: Callout.defaultStyles, dark: false,
                                        options: ReadRenderOptions(allowRemoteImages: allow))
            #expect(!out.contains("http://example.com/x.png"))
            #expect(out.contains("md-image-blocked"))
            #expect(out.contains("HTTP connection not supported"))
        }
    }

    @Test("Page carries the script-src 'none' CSP meta")
    func cspMeta() {
        #expect(doc("hi").contains(
            "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'none'\">"))
    }

    // Caution: the page head legitimately contains a <style> from HTMLTheme —
    // never assert !contains("<style") globally.
    @Test("Full pipeline: a script block arrives tagfiltered, not executable")
    func fullPipelineScript() {
        let out = doc("<script>alert(1)</script>")
        #expect(!out.contains("<script>alert"))
        #expect(out.contains("&lt;script>"))
    }
}

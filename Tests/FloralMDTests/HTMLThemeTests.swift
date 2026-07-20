// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
@testable import FloralMDCore

@Suite("HTMLTheme — CSS emission")
@MainActor
struct HTMLThemeTests {

    private func css(dark: Bool) -> String {
        let theme = EditorTheme(fontName: "Iowan Old Style", fontSize: 16,
                                linkBlueHex: "#3366E6", codeHex: "#8A2425",
                                lineSpacing: 4, paragraphSpacingBefore: 2)
        return HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: dark)
    }

    @Test("Derives custom properties from the theme")
    func vars() {
        let out = css(dark: false)
        #expect(out.contains("--accent: #3366E6;"))
        #expect(out.contains("--code: #8A2425;"))
        #expect(out.contains("--body-size: 16px;"))
        // 1.2 + 4/16 = 1.45
        #expect(out.contains("--line-height: 1.45;"))
        // Multi-word family is quoted with a fallback stack.
        #expect(out.contains("\"Iowan Old Style\""))
    }

    @Test("The default theme uses the native system-font stack")
    func systemFontStack() {
        let out = HTMLTheme.css(.default, callouts: Callout.defaultStyles, dark: false)
        #expect(out.contains("--body-font: -apple-system, sans-serif;"))
        #expect(!out.contains(EditorTheme.systemFontName))
    }

    @Test("The Read view preserves the Western then Chinese font cascade")
    func cjkFontStack() {
        var theme = EditorTheme.default
        theme.fontName = "Charter-Roman"
        theme.cjkFontName = "STSongti-SC-Regular"
        let out = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false)
        #expect(out.contains("--body-font: \"Charter-Roman\", \"STSongti-SC-Regular\", -apple-system, sans-serif;"))
    }

    @Test("Reading column max-width matches the editor's physical cap; uncapped by default")
    func pageMaxWidth() {
        let theme = EditorTheme(fontName: "Iowan Old Style", fontSize: 16,
                                linkBlueHex: "#3366E6", codeHex: "#8A2425",
                                lineSpacing: 4, paragraphSpacingBefore: 2)
        let capped = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false,
                                   maxContentWidthPoints: 340)
        #expect(capped.contains("--page-max-width: 340px;"))

        let uncapped = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false)
        #expect(uncapped.contains("--page-max-width: none;"))
    }

    @Test("Emits per-callout-type colors with derived rgba background")
    func calloutVars() {
        let out = css(dark: false)
        #expect(out.contains(".callout-note {"))
        #expect(out.contains("--c-accent: #086DDD;"))
        // note's background is derived from the accent at backgroundAlpha 0.08.
        #expect(out.contains("rgba(8, 109, 221, 0.08)"))
    }

    @Test("Dark appearance picks dark color variants")
    func darkVariant() {
        // 'caution' has darkColorHex #F85149.
        #expect(css(dark: true).contains("--c-accent: #F85149;"))
        #expect(css(dark: false).contains("--c-accent: #CF222E;"))
        #expect(css(dark: true).contains("--bg: #1e1e1e;"))
    }

    @Test("Transparent Read background leaves foreground theme colors intact")
    func transparentBackground() {
        let out = HTMLTheme.css(.default, callouts: Callout.defaultStyles,
                                dark: false, transparentBackground: true)
        #expect(out.contains("--bg: transparent;"))
        #expect(out.contains("--fg: #1a1a1a;"))
    }

    @Test("Read tables use the shared open-table presentation")
    func tablePresentation() {
        let out = css(dark: false)
        #expect(out.contains(".table-wrap { overflow-x: auto; margin: 1em 0; }"))
        #expect(out.contains("min-width: 66.667%; max-width: 100%"))
        #expect(out.contains("overflow-wrap: anywhere"))
        #expect(out.contains("thead tr, tbody tr:not(:last-child)"))
        #expect(!out.contains("th, td { border:"))
    }

    @Test("Read headings and lists use the expanded vertical rhythm")
    func expandedHeadingAndListSpacing() {
        let out = css(dark: false)
        #expect(out.contains("margin: 1.7em 0 0.7em;"))
        #expect(out.contains("margin: 1.3em 0; padding-left: 2.25em;"))
        #expect(out.contains("li { margin: 0.35em 0; }"))
    }

    @Test("Emits code token colors from the shared palette, per appearance")
    func codeTokenColors() {
        let light = css(dark: false)
        #expect(light.contains("pre code .tok-keyword { color: \(CodeSyntaxPalette.hex(.keyword, dark: false)); }"))
        #expect(light.contains("pre code { color: \(CodeSyntaxPalette.hex(nil, dark: false)); }"))
        let dark = css(dark: true)
        #expect(dark.contains("pre code .tok-string { color: \(CodeSyntaxPalette.hex(.string, dark: true)); }"))
        // The palettes differ between appearances.
        #expect(CodeSyntaxPalette.hex(.keyword, dark: false) != CodeSyntaxPalette.hex(.keyword, dark: true))
    }
}

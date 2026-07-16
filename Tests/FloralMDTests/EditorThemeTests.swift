import Testing
import AppKit
import CoreText
@testable import FloralMDCore

@Suite("EditorTheme")
struct EditorThemeMathColorTests {

    @Test("The default body font follows the native macOS system font")
    @MainActor func systemBodyFontDefault() {
        let theme = EditorTheme.default
        #expect(theme.fontName == EditorTheme.systemFontName)
        #expect(theme.bodyFont.fontName == NSFont.systemFont(ofSize: theme.fontSize).fontName)
    }

    @Test("Historical Iowan defaults migrate to the system font",
          arguments: ["Iowan Old Style", "IowanOldStyle-Roman"])
    func legacyIowanDefaultMigration(storedName: String) {
        let suite = "EditorThemeTests.legacyIowan.\(storedName)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(storedName, forKey: "EditorFontName")

        #expect(EditorTheme.load(from: defaults).fontName == EditorTheme.systemFontName)
    }

    @Test("An explicitly selected font survives default migration")
    func explicitFontIsPreserved() {
        let suite = "EditorThemeTests.explicitFont"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Charter-Roman", forKey: "EditorFontName")

        #expect(EditorTheme.load(from: defaults).fontName == "Charter-Roman")
    }

    @Test("Western and Chinese font choices persist independently")
    func independentFontPersistence() {
        let suite = "EditorThemeTests.independentFonts"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var theme = EditorTheme.default
        theme.fontName = "Charter-Roman"
        theme.cjkFontName = "STSongti-SC-Regular"
        theme.save(to: defaults)

        let loaded = EditorTheme.load(from: defaults)
        #expect(loaded.fontName == "Charter-Roman")
        #expect(loaded.cjkFontName == "STSongti-SC-Regular")
    }

    @Test("A custom Chinese font is the CJK fallback without replacing Western text")
    @MainActor func customCJKCascade() throws {
        let western = try #require(NSFont(name: "Charter-Roman", size: 16))
        let chinese = try #require(NSFont(name: "STSongti-SC-Regular", size: 16))
        var theme = EditorTheme.default
        theme.fontName = western.fontName
        theme.cjkFontName = chinese.fontName

        #expect(theme.bodyFont.fontName == western.fontName)
        let resolved = CTFontCreateForString(
            theme.bodyFont as CTFont, "中" as CFString, CFRange(location: 0, length: 1)
        ) as NSFont
        #expect(resolved.fontName == chinese.fontName)
    }

    @Test("Default math colors are red (operators) and orange (numbers)")
    @MainActor func defaults() {
        let t = EditorTheme.default
        #expect(t.mathOperatorHex == "#D70015")
        #expect(t.mathNumberHex == "#C77800")
        #expect(t.mathOperatorColor == NSColor(hex: "#D70015"))
        #expect(t.mathNumberColor == NSColor(hex: "#C77800"))
    }

    @Test("Custom math hex resolves to the matching color")
    @MainActor func customHex() {
        let t = EditorTheme(fontName: "Helvetica", fontSize: 14,
                            linkBlueHex: "#000000", codeHex: "#000000",
                            lineSpacing: 0, paragraphSpacingBefore: 0,
                            mathOperatorHex: "#112233", mathNumberHex: "#445566")
        #expect(t.mathOperatorColor == NSColor(hex: "#112233"))
        #expect(t.mathNumberColor == NSColor(hex: "#445566"))
    }

    @Test("An invalid hex falls back to a system color, not a crash")
    @MainActor func invalidHexFallback() {
        let t = EditorTheme(fontName: "Helvetica", fontSize: 14,
                            linkBlueHex: "#000000", codeHex: "#000000",
                            lineSpacing: 0, paragraphSpacingBefore: 0,
                            mathOperatorHex: "nonsense", mathNumberHex: "")
        #expect(t.mathOperatorColor == NSColor.systemRed)
        #expect(t.mathNumberColor == NSColor.systemOrange)
    }
}

import AppKit
import Testing
@testable import FloralMDCore

@Suite("Native caret and default editor spacing")
struct NativeCaretTests {
    @Test("The editor uses the native AppKit insertion point")
    @MainActor func editorUsesNativeInsertionPoint() {
        let editor = makeEditor()
        #expect(editor.insertionPointColor != .clear)
    }

    @Test("Custom spacing is normalized to the native editor default")
    @MainActor func customSpacingIsNormalized() {
        let editor = makeEditor()
        var theme = EditorTheme.default
        theme.lineSpacing = 32
        editor.applyTheme(theme, persist: false)

        #expect(editor.bodyParagraphStyle.lineSpacing == 0)
        #expect(editor.theme.lineSpacing == 0)
    }

    @Test("An old persisted custom spacing value is ignored")
    @MainActor func persistedSpacingIsIgnored() {
        let suiteName = "FloralMD.NativeCaretTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(48, forKey: "EditorLineSpacing")
        let theme = EditorTheme.load(from: defaults)
        #expect(theme.lineSpacing == 0)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Trailing source newline collapses until the EOF paragraph is active")
    @MainActor func trailingEmptyLineCollapsesOutsideEOF() {
        let editor = makeEditor()
        editor.loadContent("hello\n")

        editor.recomposeIncremental(cursorInRaw: 0, settingSelection: true)
        let collapsed = editor.textStorage!.attribute(.font, at: 5,
                                                       effectiveRange: nil) as? NSFont
        #expect(collapsed?.pointSize ?? 1 < 1)

        editor.recomposeIncremental(cursorInRaw: 6, settingSelection: true)
        let restored = editor.textStorage!.attribute(.font, at: 5,
                                                      effectiveRange: nil) as? NSFont
        #expect(restored?.pointSize ?? 0 > 1)
    }
}

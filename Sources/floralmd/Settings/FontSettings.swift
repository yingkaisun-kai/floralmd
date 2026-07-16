// FontSettings — owns the editor fonts, line height, and accent hex, bridges the
// AppKit font panel, and applies changes to every open document.

import SwiftUI
import AppKit
import FloralMDCore

// MARK: - Font / theme state

/// Owns the editor's Western/CJK/monospace fonts and line height, bridges the
/// AppKit font panel, and applies font/line-height changes to open documents
/// (the genuinely AppKit-bound part of the Appearance pane).
@MainActor
final class FontSettings: NSObject, ObservableObject {
    @Published var standardFont: NSFont
    @Published var cjkFont: NSFont
    @Published var monospaceFont: NSFont
    @Published var lineHeight: CGFloat
    @Published var standardLigatures: Bool { didSet { applyLigatures() } }
    @Published var monospaceLigatures: Bool { didSet { applyLigatures() } }
    /// A single editor-wide antialias setting (both font toggles share it).
    @Published var antialias: Bool { didSet { applyAntialias() } }

    private var theme: EditorTheme
    private enum Target { case standard, cjk, monospace }
    private var target: Target = .standard

    override init() {
        let theme = EditorTheme.load()
        self.theme = theme
        standardFont = theme.bodyFont
        cjkFont = theme.cjkFontName.isEmpty
            ? EditorTheme.systemCJKFont(ofSize: theme.fontSize)
            : NSFont(name: theme.cjkFontName, size: theme.fontSize)
                ?? EditorTheme.systemCJKFont(ofSize: theme.fontSize)
        monospaceFont = theme.monospaceFont()
        standardLigatures = theme.standardLigatures
        monospaceLigatures = theme.monospaceLigatures
        antialias = theme.antialias
        let size = theme.bodyFont.pointSize
        lineHeight = size > 0 ? max(1, min(3, (size + theme.lineSpacing) / size)) : 1
        super.init()
    }

    var standardSummary: String { Self.summary(standardFont) }
    var cjkSummary: String { Self.summary(cjkFont) }
    var monospaceSummary: String { Self.summary(monospaceFont) }
    var systemWesternName: String { "SF Pro" }
    var systemCJKName: String { Self.displayName(cjkFont) }
    var usesSystemFont: Bool { theme.fontName == EditorTheme.systemFontName }
    var usesSystemCJKFont: Bool { theme.cjkFontName.isEmpty }

    func selectStandardFont() { beginFontPanel(.standard, current: standardFont) }
    func selectCJKFont() { beginFontPanel(.cjk, current: cjkFont) }
    func selectMonospaceFont() { beginFontPanel(.monospace, current: monospaceFont) }

    func useSystemFont() {
        standardFont = .systemFont(ofSize: standardFont.pointSize)
        applyTheme()
    }

    func useSystemCJKFont() {
        cjkFont = EditorTheme.systemCJKFont(ofSize: standardFont.pointSize)
        var updated = theme
        updated.cjkFontName = ""
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    func setStandardSize(_ size: CGFloat) {
        standardFont = NSFont(descriptor: standardFont.fontDescriptor, size: size) ?? standardFont
        cjkFont = NSFont(descriptor: cjkFont.fontDescriptor, size: size) ?? cjkFont
        applyTheme()
    }

    func setMonospaceSize(_ size: CGFloat) {
        monospaceFont = NSFont(descriptor: monospaceFont.fontDescriptor, size: size) ?? monospaceFont
        applyMonospace()
    }

    func setLineHeight(_ value: CGFloat) {
        lineHeight = max(1, min(3, value))
        applyTheme()
    }

    @objc func changeFont(_ sender: NSFontManager) {
        switch target {
        case .standard:
            standardFont = sender.convert(standardFont)
            cjkFont = NSFont(descriptor: cjkFont.fontDescriptor,
                             size: standardFont.pointSize) ?? cjkFont
            applyTheme()
        case .cjk:
            let converted = sender.convert(cjkFont)
            cjkFont = NSFont(descriptor: converted.fontDescriptor,
                             size: standardFont.pointSize) ?? converted
            applyCJK()
        case .monospace:
            monospaceFont = sender.convert(monospaceFont)
            applyMonospace()
        }
    }

    private func beginFontPanel(_ target: Target, current: NSFont) {
        self.target = target
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    private func applyMonospace() {
        var updated = theme
        updated.monospaceFontName = monospaceFont.fontName
        updated.monospaceFontSize = monospaceFont.pointSize
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyCJK() {
        var updated = theme
        updated.cjkFontName = cjkFont.fontName
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyLigatures() {
        var updated = theme
        updated.standardLigatures = standardLigatures
        updated.monospaceLigatures = monospaceLigatures
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyAntialias() {
        var updated = theme
        updated.antialias = antialias
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyTheme() {
        var updated = theme
        updated.fontName = standardFont.fontName
        updated.fontSize = standardFont.pointSize
        updated.lineSpacing = max(0, (lineHeight - 1) * standardFont.pointSize)
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyToDocuments(_ theme: EditorTheme) {
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.applyTheme(theme)
            // Reflect the theme change live in an open Read view too.
            document.refreshReadView()
        }
    }

    private static func summary(_ font: NSFont) -> String {
        "\(displayName(font))  \(Int(round(font.pointSize)))"
    }

    private static func displayName(_ font: NSFont) -> String {
        let name = font.displayName ?? font.familyName ?? font.fontName
        return name.hasPrefix(".") ? String(name.dropFirst()) : name
    }
}

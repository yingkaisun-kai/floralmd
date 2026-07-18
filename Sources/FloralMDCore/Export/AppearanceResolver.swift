import AppKit

/// Resolves an AppKit appearance to the light/dark palette used by FloralMD's
/// HTML renderer.
public enum AppearanceResolver {
    @MainActor
    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

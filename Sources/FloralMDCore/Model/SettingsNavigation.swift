// Modified from Edmund by Yingkai Sun for FloralMD.
/// Stable Settings navigation identities and window layout bounds.
///
/// The app shell owns presentation and localization; this model only keeps the
/// section inventory and sizing contract testable without launching AppKit.
public enum SettingsPaneID: String, CaseIterable, Sendable {
    case general
    case editor
    case markdown
    case shortcuts
    case appearance
    case advanced
}

public enum SettingsWindowLayout {
    public static let defaultWidth = 920.0
    public static let defaultHeight = 680.0
    public static let minimumWidth = 760.0
    public static let minimumHeight = 520.0
    public static let minimumSidebarWidth = 180.0
    public static let maximumSidebarWidth = 220.0
    public static let minimumDetailWidth = 540.0
}

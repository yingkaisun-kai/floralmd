// AppSettings — UserDefaults-backed model for every Settings value.
// The rest of the app reads these accessors; the SwiftUI panes bind to the
// same keys via @AppStorage.

import AppKit
import FloralMDCore

enum AppSettings {
    enum StartupAction: String, CaseIterable, Identifiable {
        case createNewDocument
        case doNothing
        var id: Self { self }
        var label: String {
            switch self {
            case .createNewDocument: return AppCopy.text("Create New Document", "新建文档")
            case .doNothing: return AppCopy.text("Do Nothing", "不执行任何操作")
            }
        }
    }

    enum ConflictResolution: String, CaseIterable, Identifiable {
        case keepCurrent
        case ask
        case updateToModified
        var id: Self { self }
        var label: String {
            switch self {
            case .keepCurrent: return AppCopy.text("Keep FloralMD’s edition", "保留 FloralMD 中的版本")
            case .ask: return AppCopy.text("Ask how to resolve", "询问如何处理")
            case .updateToModified: return AppCopy.text("Update to modified edition", "更新为外部修改版本")
            }
        }
    }

    enum AppearanceMode: String, CaseIterable, Identifiable {
        case matchSystem
        case light
        case dark
        var id: Self { self }
        var label: String {
            switch self {
            case .matchSystem: return AppCopy.text("Match System", "跟随系统")
            case .light: return AppCopy.text("Light", "浅色")
            case .dark: return AppCopy.text("Dark", "深色")
            }
        }
        /// Display order in the Appearance pane (left to right).
        static let displayOrder: [AppearanceMode] = [.light, .dark, .matchSystem]
    }

    /// How long diagnostic logs are kept before being pruned on launch.
    enum LogRetention: String, CaseIterable, Identifiable {
        case oneDay, twoDays, oneWeek, twoWeeks, thirtyDays, never
        var id: Self { self }
        var label: String {
            switch self {
            case .oneDay: return AppCopy.text("1 day", "1 天")
            case .twoDays: return AppCopy.text("2 days", "2 天")
            case .oneWeek: return AppCopy.text("1 week", "1 周")
            case .twoWeeks: return AppCopy.text("2 weeks", "2 周")
            case .thirtyDays: return AppCopy.text("30 days", "30 天")
            case .never: return AppCopy.text("Never", "永不")
            }
        }
        /// The retention window in seconds; `nil` means keep forever.
        var timeInterval: TimeInterval? {
            let day: TimeInterval = 24 * 60 * 60
            switch self {
            case .oneDay: return day
            case .twoDays: return 2 * day
            case .oneWeek: return 7 * day
            case .twoWeeks: return 14 * day
            case .thirtyDays: return 30 * day
            case .never: return nil
            }
        }
    }

    enum Key {
        static let reopenWindows = "settings.general.reopenWindows"
        static let interfaceLanguage = "settings.general.interfaceLanguage"
        // Must match Sparkle's own default key exactly — Sparkle reads/writes this string.
        static let automaticallyChecksForUpdates = "SUAutomaticallyChecksForUpdates"
        static let startupAction = "settings.general.startupAction"
        static let quickCaptureEnabled = "settings.general.quickCaptureEnabled"
        static let quickCaptureKeyCode = "settings.general.quickCaptureKeyCode"
        static let quickCaptureModifiers = "settings.general.quickCaptureModifiers"
        static let quickCaptureKeyLabel = "settings.general.quickCaptureKeyLabel"
        static let shortcutOverrides = "settings.shortcuts.overrides"
        static let shortcutSchemaVersion = "settings.shortcuts.schemaVersion"
        static let showFixedShortcuts = "settings.shortcuts.showFixed"
        static let autoSaveWithVersions = "settings.general.autoSaveWithVersions"
        static let autoSaveInterval = "settings.general.autoSaveInterval"
        static let autoSaveUntitledDocuments = "settings.general.autoSaveUntitledDocuments"
        static let untitledDocumentDirectoryBookmark = "settings.general.untitledDocumentDirectoryBookmark"
        static let conflictResolution = "settings.general.conflictResolution"
        static let appearanceMode = "settings.appearance.mode"
        static let maxContentWidthCm = "settings.appearance.maxContentWidthCm"
        // "cm" / "in" override the locale default for the content-width control.
        static let contentWidthUnit = "settings.appearance.contentWidthUnit"
        static let suppressInconsistentLineEndingWarning = "settings.general.suppressInconsistentLineEndingWarning"
        static let diagnosticLogging = "settings.general.diagnosticLogging"
        static let verboseEditorDiagnostics = "settings.advanced.verboseEditorDiagnostics"
        static let blockExternalImages = "settings.advanced.blockExternalImages"
        static let logRetention = "settings.general.logRetention"
        static let renderBlankLinesAsBreaks = "settings.reading.renderBlankLinesAsBreaks"
        // Keep the historical key string so existing users retain their choice.
        static let typewriterMode = "EditorTypewriterMode"
        // These predate the Editor settings pane; keep their strings for compatibility.
        static let sourceMode = "settings.view.sourceMode"
        static let showMinimap = "settings.appearance.showMinimap"
        static let sendCrashLogs = "settings.advanced.sendCrashLogs"
        static let sentCrashReports = "settings.advanced.sentCrashReports"
        static let lastWindowWidth  = "settings.window.lastWidth"
        static let lastWindowHeight = "settings.window.lastHeight"
    }

    /// Maximum text-column width in centimetres. Wider windows center the
    /// column at this physical width; narrower windows fill edge-to-edge.
    /// Default: a comfortable 12 cm / 5 in reading column.
    static var maxContentWidthCm: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.maxContentWidthCm) != nil else {
                return defaultMaxContentWidthCm
            }
            return UserDefaults.standard.double(forKey: Key.maxContentWidthCm)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.maxContentWidthCm) }
    }

    /// Out-of-the-box reading column: 5 in for US locales, 12 cm elsewhere.
    /// This is also the slider's magnetic snap point.
    static var defaultMaxContentWidthCm: Double {
        Locale.current.measurementSystem == .us ? 5.0 * 2.54 : 12.0
    }

    /// Full frame size of the last document window, to reopen new windows at the
    /// same dimensions (applied via setFrame). Returns nil when nothing is saved.
    /// The floor only rejects garbage/zero values — every real window size,
    /// including ones smaller than the default, is remembered.
    static var lastWindowSize: NSSize? {
        get {
            let w = UserDefaults.standard.double(forKey: Key.lastWindowWidth)
            let h = UserDefaults.standard.double(forKey: Key.lastWindowHeight)
            guard w >= 100, h >= 100 else { return nil }
            return NSSize(width: w, height: h)
        }
        set {
            guard let s = newValue else { return }
            UserDefaults.standard.set(Double(s.width),  forKey: Key.lastWindowWidth)
            UserDefaults.standard.set(Double(s.height), forKey: Key.lastWindowHeight)
        }
    }

    static var reopenWindows: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reopenWindows) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reopenWindows) }
    }

    static var interfaceLanguage: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.interfaceLanguage),
                  let language = AppLanguage(rawValue: raw) else { return .system }
            return language
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.interfaceLanguage) }
    }

    /// Keeps the insertion point vertically centred while typing. Defaults on,
    /// matching FloralMD's historical editing behaviour.
    static var typewriterMode: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.typewriterMode) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.typewriterMode)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.typewriterMode) }
    }

    /// Source mode: an alternate form of Edit mode that shows the raw markdown.
    /// When on, the editing half of the view-mode toggle is Source instead of
    /// Edit (so the toggle flips Source ↔ Read). Defaults off.
    static var sourceMode: Bool {
        get { UserDefaults.standard.bool(forKey: Key.sourceMode) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sourceMode) }
    }

    /// Semantic document minimap beside the editor. Defaults on.
    static var showMinimap: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.showMinimap) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.showMinimap)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.showMinimap) }
    }

    /// Read mode: render runs of blank lines as proportional vertical space
    /// (preserving the author's spacing). Defaults on. The toggle UI lives in a
    /// future Reading-settings tab; the value is already honored here.
    static var renderBlankLinesAsBreaks: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.renderBlankLinesAsBreaks) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.renderBlankLinesAsBreaks)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.renderBlankLinesAsBreaks) }
    }

    static var startupAction: StartupAction {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.startupAction),
                  let action = StartupAction(rawValue: raw) else {
                return .createNewDocument
            }
            return action
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.startupAction) }
    }

    static var quickCaptureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.quickCaptureEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.quickCaptureEnabled) }
    }

    static var shortcutOverrides: [String: ShortcutOverride] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.shortcutOverrides),
                  let decoded = try? JSONDecoder().decode(
                    [String: ShortcutOverride].self,
                    from: data
                  ) else { return [:] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Key.shortcutOverrides)
        }
    }

    static func effectiveShortcut(for commandID: String) -> CommandShortcut? {
        guard let definition = ShortcutCatalog.byID[commandID] else { return nil }
        guard definition.isCustomizable else { return definition.defaultShortcut }
        if let override = shortcutOverrides[commandID] {
            switch override {
            case .shortcut(let shortcut): return shortcut
            case .disabled: return nil
            }
        }
        return definition.defaultShortcut
    }

    static func setShortcutOverride(_ override: ShortcutOverride?, for commandID: String) {
        var overrides = shortcutOverrides
        overrides[commandID] = override
        shortcutOverrides = overrides
    }

    static var quickCaptureShortcut: CommandShortcut? {
        effectiveShortcut(for: "file.quickCapture")
    }

    static func migrateShortcutSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Key.shortcutSchemaVersion) < 1 else { return }
        if defaults.object(forKey: Key.quickCaptureKeyCode) != nil,
           defaults.object(forKey: Key.quickCaptureModifiers) != nil,
           let label = defaults.string(forKey: Key.quickCaptureKeyLabel),
           !label.isEmpty {
            let shortcut = CommandShortcut.global(
                UInt16(clamping: defaults.integer(forKey: Key.quickCaptureKeyCode)),
                keyEquivalent: label.lowercased(),
                keyLabel: label,
                modifiers: NSEvent.ModifierFlags(
                    rawValue: UInt(defaults.integer(forKey: Key.quickCaptureModifiers))
                )
            )
            setShortcutOverride(.shortcut(shortcut), for: "file.quickCapture")
        }
        defaults.set(1, forKey: Key.shortcutSchemaVersion)
    }

    static var autoSaveWithVersions: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.autoSaveWithVersions) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.autoSaveWithVersions)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoSaveWithVersions) }
    }

    static var autoSaveInterval: TimeInterval {
        get {
            guard UserDefaults.standard.object(forKey: Key.autoSaveInterval) != nil else {
                return DocumentAutoSaveInterval.defaultValue.rawValue
            }
            return DocumentAutoSaveInterval.resolved(
                UserDefaults.standard.double(forKey: Key.autoSaveInterval)
            ).rawValue
        }
        set {
            UserDefaults.standard.set(
                DocumentAutoSaveInterval.resolved(newValue).rawValue,
                forKey: Key.autoSaveInterval
            )
        }
    }

    /// First-save automation is intentionally independent from periodic
    /// autosaving of documents that already have a file URL. Defaults off.
    static var autoSaveUntitledDocuments: Bool {
        get { UserDefaults.standard.bool(forKey: Key.autoSaveUntitledDocuments) }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoSaveUntitledDocuments) }
    }

    static func storeUntitledDocumentDirectory(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Key.untitledDocumentDirectoryBookmark)
    }

    static func untitledDocumentDirectoryURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(
            forKey: Key.untitledDocumentDirectoryBookmark
        ) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale, let refreshed = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(
                refreshed,
                forKey: Key.untitledDocumentDirectoryBookmark
            )
        }
        return url
    }

    /// Centralize directory access so enabling App Sandbox later only changes
    /// this boundary, not Document's save lifecycle.
    static func accessUntitledDocumentDirectory() -> UntitledDocumentDirectoryAccess? {
        untitledDocumentDirectoryURL().map(UntitledDocumentDirectoryAccess.init)
    }

    /// Applies the persisted save mode immediately. `autosavesInPlace` only
    /// declares support; AppKit's periodic timer remains disabled until its
    /// delay is greater than zero.
    @MainActor static func applyDocumentSaving() {
        NSDocumentController.shared.autosavingDelay = DocumentSavePolicy.autosavingDelay(
            automaticSavingEnabled: autoSaveWithVersions,
            requestedInterval: autoSaveInterval
        )
    }

    static var conflictResolution: ConflictResolution {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.conflictResolution),
                  let resolution = ConflictResolution(rawValue: raw) else {
                return .ask
            }
            return resolution
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.conflictResolution) }
    }

    static var appearanceMode: AppearanceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.appearanceMode),
                  let mode = AppearanceMode(rawValue: raw) else {
                return .matchSystem
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.appearanceMode) }
    }

    static var suppressInconsistentLineEndingWarning: Bool {
        get { UserDefaults.standard.bool(forKey: Key.suppressInconsistentLineEndingWarning) }
        set { UserDefaults.standard.set(newValue, forKey: Key.suppressInconsistentLineEndingWarning) }
    }

    /// Whether diagnostic logging is on. Defaults to off; the user can opt in.
    static var diagnosticLogging: Bool {
        get { UserDefaults.standard.bool(forKey: Key.diagnosticLogging) }
        set { UserDefaults.standard.set(newValue, forKey: Key.diagnosticLogging) }
    }

    /// Verbose editor tracing: high-volume per-edit / per-caret-move trace lines
    /// for diagnosing live-NSTextView / TextKit 2 editor bugs (caret drift, sync
    /// desyncs) that can't be reproduced headlessly. Off by default — turned on
    /// only when capturing a reproduction. Requires diagnostic logging to be on.
    static var verboseEditorDiagnostics: Bool {
        get { UserDefaults.standard.bool(forKey: Key.verboseEditorDiagnostics) }
        set { UserDefaults.standard.set(newValue, forKey: Key.verboseEditorDiagnostics) }
    }

    /// Whether Read mode / export blocks remote (`http`/`https`) image loads.
    /// Defaults on: no surprise network requests until the user opts out.
    static var blockExternalImages: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.blockExternalImages) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.blockExternalImages)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.blockExternalImages) }
    }

    /// Whether to auto-send crash reports on launch. Opt-in: defaults off, since
    /// it sends data off-device. (UI currently commented out — see
    /// AdvancedSettingsView — until the receiving server exists.)
    static var sendCrashLogs: Bool {
        get { UserDefaults.standard.bool(forKey: Key.sendCrashLogs) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sendCrashLogs) }
    }

    /// Filenames of crash reports already uploaded, so we don't resend them.
    /// Bounded on write by dropping entries whose `.ips` file no longer exists.
    static var sentCrashReports: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.sentCrashReports) ?? []) }
        set {
            let onDisk = (try? FileManager.default.contentsOfDirectory(
                atPath: CrashReporter.diagnosticReportsDirectory.path)).map(Set.init) ?? []
            let pruned = onDisk.isEmpty ? newValue : newValue.intersection(onDisk)
            UserDefaults.standard.set(Array(pruned), forKey: Key.sentCrashReports)
        }
    }

    static var logRetention: LogRetention {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.logRetention),
                  let value = LogRetention(rawValue: raw) else {
                return .twoWeeks
            }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.logRetention) }
    }

    /// Production and Debug logs must never share a directory.
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppIdentity.logDirectoryComponent, isDirectory: true)
    }

    /// Pushes the current logging settings into the `Log` facility. Called at
    /// launch and whenever the toggle or retention changes.
    static func applyLogging() {
        Log.configure(enabled: diagnosticLogging,
                      directory: logDirectory,
                      retention: logRetention.timeInterval)
        Log.setVerbose(verboseEditorDiagnostics)
    }

    @MainActor static func applyAppearance() {
        switch appearanceMode {
        case .matchSystem:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

final class UntitledDocumentDirectoryAccess {
    let url: URL
    private let startedSecurityScope: Bool

    init(url: URL) {
        self.url = url
        startedSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if startedSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

extension Notification.Name {
    static let untitledAutoSaveSettingsDidChange = Notification.Name(
        "FloralMDUntitledAutoSaveSettingsDidChange"
    )
    static let quickCaptureSettingsDidChange = Notification.Name(
        "FloralMDQuickCaptureSettingsDidChange"
    )
    static let shortcutSettingsDidChange = Notification.Name(
        "FloralMDShortcutSettingsDidChange"
    )
    static let keyboardInputSourceDidChange = Notification.Name(
        "FloralMDKeyboardInputSourceDidChange"
    )
}

// MARK: - Screen physical-unit helpers

extension NSScreen {
    /// Physical pixels-per-inch from the display's actual diagonal/width size
    /// (via Core Graphics — not the nominal 72 pt/in). Falls back to 109 PPI
    /// (the typical value for a 27-inch 5K iMac) when the display ID can't be read.
    var physicalPPI: CGFloat {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 109
        }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
        guard mm.width > 0 else { return 109 }
        // frame.width is in points (not pixels); mm.width is physical mm.
        return frame.width / (mm.width / 25.4)
    }

    /// Convert a physical centimetre value to AppKit points on this display.
    func cmToPoints(_ cm: Double) -> CGFloat {
        CGFloat(cm) / 2.54 * physicalPPI
    }

    /// The display's full physical width in centimetres.
    var physicalWidthCm: Double {
        Double(frame.width / physicalPPI) * 2.54
    }
}

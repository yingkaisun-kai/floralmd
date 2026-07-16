import AppKit
import FloralMDCore

@MainActor
enum ShortcutManager {
    static func configure(_ item: NSMenuItem, commandID: String) {
        item.identifier = NSUserInterfaceItemIdentifier(commandID)
        guard let shortcut = AppSettings.effectiveShortcut(for: commandID),
              shortcut.scope == .application else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = shortcut.keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifiers
    }

    static func effectiveShortcuts() -> [String: CommandShortcut] {
        Dictionary(uniqueKeysWithValues: ShortcutCatalog.definitions.compactMap { definition in
            AppSettings.effectiveShortcut(for: definition.id).map {
                (definition.id, normalizedForCurrentLayout($0))
            }
        })
    }

    static func conflictOwner(for shortcut: CommandShortcut,
                              excluding commandID: String) -> String? {
        effectiveShortcuts().first {
            $0.key != commandID && $0.value.collisionKey == shortcut.collisionKey
        }?.key
    }

    static func apply(_ shortcut: CommandShortcut?, to commandID: String) {
        guard let definition = ShortcutCatalog.byID[commandID],
              definition.isCustomizable else { return }
        if let shortcut {
            AppSettings.setShortcutOverride(.shortcut(shortcut), for: commandID)
        } else {
            AppSettings.setShortcutOverride(.disabled, for: commandID)
        }
        NotificationCenter.default.post(name: .shortcutSettingsDidChange, object: commandID)
    }

    static func restoreDefault(for commandID: String) {
        AppSettings.setShortcutOverride(nil, for: commandID)
        NotificationCenter.default.post(name: .shortcutSettingsDidChange, object: commandID)
    }

    static func restoreAllDefaults() {
        AppSettings.shortcutOverrides = [:]
        NotificationCenter.default.post(name: .shortcutSettingsDidChange, object: nil)
    }

    static func displayName(for shortcut: CommandShortcut) -> String {
        guard shortcut.scope == .global,
              let keyCode = shortcut.keyCode,
              let label = KeyboardLayoutResolver.label(for: keyCode),
              !label.isEmpty else { return shortcut.displayName }
        return modifierPrefix(for: shortcut.modifiers) + label
    }

    private static func normalizedForCurrentLayout(_ shortcut: CommandShortcut)
        -> CommandShortcut {
        guard shortcut.scope == .global,
              let keyCode = shortcut.keyCode,
              let label = KeyboardLayoutResolver.label(for: keyCode),
              !label.isEmpty else { return shortcut }
        return .global(
            keyCode,
            keyEquivalent: label.lowercased(),
            keyLabel: label,
            modifiers: shortcut.modifiers
        )
    }

    private static func modifierPrefix(for modifiers: NSEvent.ModifierFlags) -> String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value
    }
}

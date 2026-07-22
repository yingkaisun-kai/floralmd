import AppKit
import Foundation
import Testing
@testable import FloralMDCore

@Suite("Shortcut catalog")
struct ShortcutCatalogTests {
    @Test("Every command has a unique stable ID")
    func uniqueIDs() {
        let ids = ShortcutCatalog.definitions.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ShortcutCatalog.byID.count == ids.count)
    }

    @Test("Default shortcuts have no collisions")
    func defaultsDoNotCollide() {
        let defaults = Dictionary(uniqueKeysWithValues:
            ShortcutCatalog.definitions.compactMap { definition in
                definition.defaultShortcut.map { (definition.id, $0) }
            }
        )
        #expect(ShortcutCatalog.conflicts(in: defaults).isEmpty)
    }

    @Test("Application and global shortcuts with the same chord conflict")
    func globalConflictsWithApplicationChord() {
        let shortcuts = [
            "view.toggleMode": CommandShortcut.application(
                "e",
                [.command, .option]
            ),
            "file.quickCapture": CommandShortcut.global(
                14,
                keyEquivalent: "e",
                keyLabel: "E",
                modifiers: [.command, .option]
            ),
        ]

        let conflicts = ShortcutCatalog.conflicts(in: shortcuts)
        #expect(conflicts["view.toggleMode"] == "file.quickCapture")
        #expect(conflicts["file.quickCapture"] == "view.toggleMode")
    }

    @Test("Shortcut overrides round-trip disabled and assigned values")
    func overridesRoundTrip() throws {
        let source: [String: ShortcutOverride] = [
            "view.toggleMinimap": .disabled,
            "window.toggleAlwaysOnTop": .shortcut(
                .application("t", [.command, .control])
            ),
            "file.quickCapture": .shortcut(
                .global(
                    45,
                    keyEquivalent: "n",
                    keyLabel: "N",
                    modifiers: [.command, .option, .control]
                )
            ),
        ]

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(
            [String: ShortcutOverride].self,
            from: data
        )
        #expect(decoded == source)
    }

    @Test("Display order follows standard macOS modifier notation")
    func displayName() {
        let shortcut = CommandShortcut.application(
            "k",
            [.control, .option, .shift, .command]
        )
        #expect(shortcut.displayName == "⌃⌥⇧⌘K")
    }

    @Test("Command palette exposes safe discoverable commands")
    func commandPaletteCommands() {
        let commandIDs = Set(
            ShortcutCatalog.definitions
                .filter(\.appearsInCommandPalette)
                .map(\.id)
        )

        #expect(commandIDs.contains("app.settings"))
        #expect(commandIDs.contains("file.quickCapture"))
        #expect(commandIDs.contains("file.openRecent"))
        #expect(commandIDs.contains("view.toggleFullScreen"))
        #expect(commandIDs.contains("window.compact"))
        #expect(commandIDs.contains("format.bold"))
        #expect(!commandIDs.contains("app.quit"))
        #expect(!commandIDs.contains("edit.paste"))
        #expect(!commandIDs.contains("app.commandPalette"))
    }

    @Test("Window command defaults match the native and palette contracts")
    func windowCommandDefaults() {
        #expect(
            ShortcutCatalog.byID["view.toggleFullScreen"]?.defaultShortcut
                == .application("f", [.command, .control])
        )
        #expect(
            ShortcutCatalog.byID["app.commandPalette"]?.defaultShortcut
                == .application("p", [.command, .shift])
        )
        #expect(
            ShortcutCatalog.byID["file.openRecent"]?.defaultShortcut
                == .application("r", [.control])
        )
        #expect(
            ShortcutCatalog.byID["file.new"]?.defaultShortcut
                == .application("n", [.command])
        )
        #expect(
            ShortcutCatalog.byID["file.newWindow"]?.defaultShortcut
                == .application("n", [.command, .shift])
        )
        #expect(ShortcutCatalog.byID["file.openInNewWindow"]?.defaultShortcut == nil)
        #expect(ShortcutCatalog.byID["window.compact"]?.defaultShortcut == nil)
    }

    @Test("Presentation refresh preserves the active shortcut search")
    func presentationRefreshPreservesSearch() {
        var state = ShortcutSettingsState(searchText: "bold")

        state.refreshPresentation()

        #expect(state.presentationRevision == 1)
        #expect(state.searchText == "bold")
    }
}

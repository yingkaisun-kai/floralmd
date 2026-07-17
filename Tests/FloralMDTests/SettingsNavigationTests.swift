import Testing
@testable import FloralMDCore

@Suite("Settings navigation")
struct SettingsNavigationTests {
    @Test("Every existing pane remains reachable in a stable order")
    func paneInventory() {
        #expect(SettingsPaneID.allCases == [
            .general,
            .editor,
            .shortcuts,
            .appearance,
            .advanced,
        ])
        #expect(Set(SettingsPaneID.allCases.map(\.rawValue)).count == SettingsPaneID.allCases.count)
    }

    @Test("Window bounds always leave room for the fixed sidebar and detail pane")
    func windowBounds() {
        #expect(SettingsWindowLayout.minimumSidebarWidth <= SettingsWindowLayout.maximumSidebarWidth)
        #expect(
            SettingsWindowLayout.minimumWidth
                >= SettingsWindowLayout.minimumSidebarWidth + SettingsWindowLayout.minimumDetailWidth
        )
        #expect(SettingsWindowLayout.defaultWidth >= SettingsWindowLayout.minimumWidth)
        #expect(SettingsWindowLayout.defaultHeight >= SettingsWindowLayout.minimumHeight)
    }
}

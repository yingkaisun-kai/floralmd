import Testing
@testable import FloralMDCore

@Suite("GeneralSettingsTogglePolicy")
struct GeneralSettingsTogglePolicyTests {
    private let off = GeneralSettingsToggleState(
        autoSaveUntitledDocuments: false,
        quickCaptureEnabled: false
    )

    @Test("Enabling untitled auto-save requests a directory before committing")
    func enablingUntitledAutoSaveNeedsDirectory() {
        #expect(GeneralSettingsTogglePolicy.transition(
            from: off,
            intent: .setAutoSaveUntitledDocuments(true),
            hasUntitledDirectory: false
        ) == .chooseDirectory(GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: false
        )))
    }

    @Test("Enabling untitled auto-save commits when a directory exists")
    func enablingUntitledAutoSaveWithDirectory() {
        #expect(GeneralSettingsTogglePolicy.transition(
            from: off,
            intent: .setAutoSaveUntitledDocuments(true),
            hasUntitledDirectory: true
        ) == .commit(GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: false
        )))
    }

    @Test("Enabling Quick Capture also enables untitled auto-save")
    func enablingQuickCaptureEnablesUntitledAutoSave() {
        #expect(GeneralSettingsTogglePolicy.transition(
            from: off,
            intent: .setQuickCaptureEnabled(true),
            hasUntitledDirectory: true
        ) == .commit(GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: true
        )))
    }

    @Test("Enabling Quick Capture requests a directory before committing both settings")
    func enablingQuickCaptureNeedsDirectory() {
        #expect(GeneralSettingsTogglePolicy.transition(
            from: off,
            intent: .setQuickCaptureEnabled(true),
            hasUntitledDirectory: false
        ) == .chooseDirectory(GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: true
        )))
    }

    @Test("Cancelling directory selection preserves the original disabled settings")
    func cancellingDirectorySelectionPreservesOriginalState() {
        let proposed = GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: true
        )
        #expect(GeneralSettingsTogglePolicy.completingDirectorySelection(
            originalState: off,
            proposedState: proposed,
            selectedDirectory: false
        ) == off)
    }

    @Test("Selecting a directory commits the proposed settings")
    func selectingDirectoryCommitsProposedState() {
        let proposed = GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: true
        )
        #expect(GeneralSettingsTogglePolicy.completingDirectorySelection(
            originalState: off,
            proposedState: proposed,
            selectedDirectory: true
        ) == proposed)
    }

    @Test("Disabling untitled auto-save also disables Quick Capture")
    func disablingUntitledAutoSaveDisablesQuickCapture() {
        let enabled = GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: true
        )
        #expect(GeneralSettingsTogglePolicy.transition(
            from: enabled,
            intent: .setAutoSaveUntitledDocuments(false),
            hasUntitledDirectory: true
        ) == .commit(off))
    }

    @Test("Disabling Quick Capture leaves untitled auto-save enabled")
    func disablingQuickCaptureLeavesUntitledAutoSaveEnabled() {
        let enabled = GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: true
        )
        #expect(GeneralSettingsTogglePolicy.transition(
            from: enabled,
            intent: .setQuickCaptureEnabled(false),
            hasUntitledDirectory: true
        ) == .commit(GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: false
        )))
    }

    @Test("An unresolved directory bookmark disables dependent settings")
    func unresolvedBookmarkDisablesDependentSettings() {
        let enabled = GeneralSettingsToggleState(
            autoSaveUntitledDocuments: true,
            quickCaptureEnabled: true
        )
        #expect(GeneralSettingsTogglePolicy.normalized(
            enabled,
            hasUntitledDirectory: false
        ) == off)
    }
}

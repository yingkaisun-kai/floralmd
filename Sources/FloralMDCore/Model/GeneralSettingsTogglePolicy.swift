public struct GeneralSettingsToggleState: Equatable, Sendable {
    public var autoSaveUntitledDocuments: Bool
    public var quickCaptureEnabled: Bool

    public init(autoSaveUntitledDocuments: Bool, quickCaptureEnabled: Bool) {
        self.autoSaveUntitledDocuments = autoSaveUntitledDocuments
        self.quickCaptureEnabled = quickCaptureEnabled
    }
}

public enum GeneralSettingsToggleIntent: Equatable, Sendable {
    case setAutoSaveUntitledDocuments(Bool)
    case setQuickCaptureEnabled(Bool)
}

public enum GeneralSettingsToggleTransition: Equatable, Sendable {
    case commit(GeneralSettingsToggleState)
    case chooseDirectory(GeneralSettingsToggleState)
}

public enum GeneralSettingsTogglePolicy {
    public static func transition(
        from state: GeneralSettingsToggleState,
        intent: GeneralSettingsToggleIntent,
        hasUntitledDirectory: Bool
    ) -> GeneralSettingsToggleTransition {
        switch intent {
        case .setAutoSaveUntitledDocuments(true):
            let proposed = GeneralSettingsToggleState(
                autoSaveUntitledDocuments: true,
                quickCaptureEnabled: state.quickCaptureEnabled
            )
            return hasUntitledDirectory ? .commit(proposed) : .chooseDirectory(proposed)

        case .setAutoSaveUntitledDocuments(false):
            return .commit(GeneralSettingsToggleState(
                autoSaveUntitledDocuments: false,
                quickCaptureEnabled: false
            ))

        case .setQuickCaptureEnabled(true):
            let proposed = GeneralSettingsToggleState(
                autoSaveUntitledDocuments: true,
                quickCaptureEnabled: true
            )
            return hasUntitledDirectory ? .commit(proposed) : .chooseDirectory(proposed)

        case .setQuickCaptureEnabled(false):
            return .commit(GeneralSettingsToggleState(
                autoSaveUntitledDocuments: state.autoSaveUntitledDocuments,
                quickCaptureEnabled: false
            ))
        }
    }

    public static func normalized(
        _ state: GeneralSettingsToggleState,
        hasUntitledDirectory: Bool
    ) -> GeneralSettingsToggleState {
        guard hasUntitledDirectory else {
            return GeneralSettingsToggleState(
                autoSaveUntitledDocuments: false,
                quickCaptureEnabled: false
            )
        }
        guard state.autoSaveUntitledDocuments else {
            return GeneralSettingsToggleState(
                autoSaveUntitledDocuments: false,
                quickCaptureEnabled: false
            )
        }
        return state
    }

    public static func completingDirectorySelection(
        originalState: GeneralSettingsToggleState,
        proposedState: GeneralSettingsToggleState,
        selectedDirectory: Bool
    ) -> GeneralSettingsToggleState {
        selectedDirectory ? proposedState : originalState
    }
}

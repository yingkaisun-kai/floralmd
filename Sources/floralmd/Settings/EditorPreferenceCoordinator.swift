import AppKit

/// Applies persisted editor preferences to every open document. Settings panes,
/// menus, and their keyboard equivalents all route through these setters so a
/// global preference cannot leave already-open windows in different states.
@MainActor
enum EditorPreferenceCoordinator {
    static func setTypewriterMode(_ enabled: Bool) {
        AppSettings.typewriterMode = enabled
        forEachDocument { $0.editor?.typewriterModeEnabled = enabled }
    }

    static func setSourceMode(_ enabled: Bool) {
        AppSettings.sourceMode = enabled
        forEachDocument { $0.refreshSourceModePreference() }
    }

    static func setShowMinimap(_ enabled: Bool) {
        AppSettings.showMinimap = enabled
        forEachDocument { $0.refreshMinimapVisibility() }
    }

    static func refreshMarkdownFeatures() {
        let features = AppSettings.markdownFeatures
        forEachDocument {
            $0.editor?.markdownFeatures = features
            $0.refreshReadView()
        }
    }

    private static func forEachDocument(_ apply: (Document) -> Void) {
        for case let document as Document in NSDocumentController.shared.documents {
            apply(document)
        }
    }
}

/// Pure ownership decisions for the document-based application lifecycle.
public enum ApplicationLifecyclePolicy {
    public enum ReopenHandling: Equatable, Sendable {
        /// Let AppKit run its standard reopen behavior. With no visible windows,
        /// AppKit owns the single untitled-document creation request.
        case appKitDefault
        case suppress
    }

    public static func shouldOpenUntitledFileAtLaunch(
        hasExplicitFileRequest: Bool,
        startupCreatesNewDocument: Bool
    ) -> Bool {
        !hasExplicitFileRequest && startupCreatesNewDocument
    }

    public static func reopenHandling(
        hasVisibleWindows: Bool,
        startupCreatesNewDocument: Bool
    ) -> ReopenHandling {
        if hasVisibleWindows || startupCreatesNewDocument {
            return .appKitDefault
        }
        return .suppress
    }

    public static func shouldCloseUntouchedUntitledAfterOpeningExistingFile(
        hasFileURL: Bool,
        isDocumentEdited: Bool
    ) -> Bool {
        !hasFileURL && !isDocumentEdited
    }
}

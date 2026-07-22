/// Pure ownership decisions for the document-based application lifecycle.
public enum ApplicationLifecyclePolicy {
    public enum DocumentOpenPresentation: Equatable, Sendable {
        case currentTabGroup
        case newWindow
    }

    public enum NewDocumentRequest: Equatable, Sendable {
        case tab
        case window
    }

    public enum HiddenDocumentPresentationCompletion: Equatable, Sendable {
        /// The native tab path has no later presentation callback, so it owns
        /// the document's post-load setup as soon as activation is complete.
        case afterNativeTabActivation
        /// The all-Spaces panel path completes asynchronously after the panel
        /// has joined and activated its auxiliary tab group.
        case deferredToAllSpacesPanel
    }

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

    /// Returns the first positional launch argument, ignoring the key/value
    /// pairs AppKit, UserDefaults, and FloralMD diagnostics put on the command
    /// line. In particular, `-ApplePersistenceIgnoreState YES` is launch
    /// hygiene, not a request to open a document named after the flag.
    public static func explicitDocumentPath(in arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let pathIndex = arguments.index(after: index)
                return pathIndex < arguments.endIndex ? arguments[pathIndex] : nil
            }
            if argument.hasPrefix("-") {
                index += 1
                if index < arguments.count, !arguments[index].hasPrefix("-") {
                    index += 1
                }
                continue
            }
            return argument
        }
        return nil
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

    public static func documentOpenPresentation(
        hasSourceWindow: Bool,
        requestsNewWindow: Bool
    ) -> DocumentOpenPresentation {
        if hasSourceWindow && !requestsNewWindow {
            return .currentTabGroup
        }
        return .newWindow
    }

    public static func newDocumentPresentation(
        hasOrdinarySourceWindow: Bool,
        request: NewDocumentRequest
    ) -> DocumentOpenPresentation {
        if hasOrdinarySourceWindow && request == .tab {
            return .currentTabGroup
        }
        return .newWindow
    }

    public static func hiddenDocumentPresentationCompletion(
        activatedIncrementallyInAllSpaces: Bool
    ) -> HiddenDocumentPresentationCompletion {
        activatedIncrementallyInAllSpaces
            ? .deferredToAllSpacesPanel
            : .afterNativeTabActivation
    }
}

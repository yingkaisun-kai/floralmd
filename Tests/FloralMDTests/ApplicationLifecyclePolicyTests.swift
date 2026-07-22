import Testing
@testable import FloralMDCore

@Suite("ApplicationLifecyclePolicy")
struct ApplicationLifecyclePolicyTests {
    @Test("Dock reopen delegates one untitled creation request to AppKit")
    func dockReopenHasSingleOwner() {
        let handling = ApplicationLifecyclePolicy.reopenHandling(
            hasVisibleWindows: false,
            startupCreatesNewDocument: true
        )

        #expect(handling == .appKitDefault)
    }

    @Test("Dock reopen with visible windows performs only normal activation")
    func dockReopenWithVisibleWindowsUsesDefaultHandling() {
        let handling = ApplicationLifecyclePolicy.reopenHandling(
            hasVisibleWindows: true,
            startupCreatesNewDocument: true
        )

        #expect(handling == .appKitDefault)
    }

    @Test("Dock reopen honors the do-nothing startup action")
    func dockReopenCanSuppressUntitledCreation() {
        let handling = ApplicationLifecyclePolicy.reopenHandling(
            hasVisibleWindows: false,
            startupCreatesNewDocument: false
        )

        #expect(handling == .suppress)
    }

    @Test("An explicit file launch never requests an accompanying untitled document")
    func existingFileLaunchDoesNotRequestUntitled() {
        #expect(!ApplicationLifecyclePolicy.shouldOpenUntitledFileAtLaunch(
            hasExplicitFileRequest: true,
            startupCreatesNewDocument: true
        ))
    }

    @Test("Opening an existing file cleans up only an untouched in-memory untitled document")
    func existingFileOpenCleanupPreservesRealDrafts() {
        #expect(ApplicationLifecyclePolicy.shouldCloseUntouchedUntitledAfterOpeningExistingFile(
            hasFileURL: false,
            isDocumentEdited: false
        ))
        #expect(!ApplicationLifecyclePolicy.shouldCloseUntouchedUntitledAfterOpeningExistingFile(
            hasFileURL: false,
            isDocumentEdited: true
        ))
        #expect(!ApplicationLifecyclePolicy.shouldCloseUntouchedUntitledAfterOpeningExistingFile(
            hasFileURL: true,
            isDocumentEdited: false
        ))
    }

    @Test("Open joins the source tab group when a document window is available")
    func openUsesCurrentTabGroup() {
        #expect(ApplicationLifecyclePolicy.documentOpenPresentation(
            hasSourceWindow: true,
            requestsNewWindow: false
        ) == .currentTabGroup)
    }

    @Test("Open Recent shares Command-O's current tab group presentation")
    func openRecentUsesCurrentTabGroup() {
        #expect(ApplicationLifecyclePolicy.documentOpenPresentation(
            hasSourceWindow: true,
            requestsNewWindow: false
        ) == .currentTabGroup)
    }

    @Test("Open creates a window when there is no source document window")
    func openWithoutSourceUsesNewWindow() {
        #expect(ApplicationLifecyclePolicy.documentOpenPresentation(
            hasSourceWindow: false,
            requestsNewWindow: false
        ) == .newWindow)
    }

    @Test("Open in New Window never joins the source tab group")
    func explicitNewWindowStaysSeparate() {
        #expect(ApplicationLifecyclePolicy.documentOpenPresentation(
            hasSourceWindow: true,
            requestsNewWindow: true
        ) == .newWindow)
    }

    @Test("Command-N joins the current ordinary document tab group")
    func newTabUsesCurrentGroup() {
        #expect(ApplicationLifecyclePolicy.newDocumentPresentation(
            hasOrdinarySourceWindow: true,
            request: .tab
        ) == .currentTabGroup)
    }

    @Test("Command-N creates the first window when no ordinary document exists")
    func newTabWithoutSourceCreatesWindow() {
        #expect(ApplicationLifecyclePolicy.newDocumentPresentation(
            hasOrdinarySourceWindow: false,
            request: .tab
        ) == .newWindow)
    }

    @Test("Command-Shift-N stays a new window even beside an ordinary document")
    func explicitNewDocumentWindowStaysSeparate() {
        #expect(ApplicationLifecyclePolicy.newDocumentPresentation(
            hasOrdinarySourceWindow: true,
            request: .window
        ) == .newWindow)
    }

    @Test("Native hidden tabs finish after activation; all-Spaces tabs defer to their panel")
    func hiddenTabCompletionHasOneOwner() {
        #expect(ApplicationLifecyclePolicy.hiddenDocumentPresentationCompletion(
            activatedIncrementallyInAllSpaces: false
        ) == .afterNativeTabActivation)
        #expect(ApplicationLifecyclePolicy.hiddenDocumentPresentationCompletion(
            activatedIncrementallyInAllSpaces: true
        ) == .deferredToAllSpacesPanel)
    }
}

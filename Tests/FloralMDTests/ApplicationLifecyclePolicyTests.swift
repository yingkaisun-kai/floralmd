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
}

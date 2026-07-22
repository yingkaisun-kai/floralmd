import Testing
@testable import FloralMDCore

@Suite("Document sidebar session state")
struct DocumentSidebarSessionStateTests {
    @Test("Every new document window starts with both sidebars collapsed")
    func initialState() {
        let state = DocumentSidebarSessionState()
        #expect(!state.isOutlineExpanded)
        #expect(!state.isNavigationExpanded)
        #expect(state.navigationWidth == DocumentNavigationSidebarWidthPolicy.defaultWidth)
        #expect(state.navigationMode == .files)
        #expect(state.gitMode == .changes)
    }

    @Test("Manual expansion remains in the window session")
    func manualExpansionPersists() {
        var state = DocumentSidebarSessionState()
        state.setOutlineExpanded(true)
        state.setNavigationExpanded(true)

        #expect(state.isOutlineExpanded)
        #expect(state.isNavigationExpanded)

        state.setNavigationExpanded(false)
        #expect(!state.isNavigationExpanded)

        state.setNavigationExpanded(true)
        #expect(state.isNavigationExpanded)
    }

    @Test("Width and nested Git mode survive collapse and reopen")
    func navigationPresentationPersists() {
        var state = DocumentSidebarSessionState()
        state.setNavigationWidth(360)
        state.setNavigationMode(.git)
        state.setGitMode(.history)
        state.setNavigationExpanded(true)
        state.setNavigationExpanded(false)

        #expect(state.navigationWidth == 360)
        #expect(state.navigationMode == .git)
        #expect(state.gitMode == .history)

        state.setNavigationExpanded(true)
        #expect(state.navigationWidth == 360)
        #expect(state.navigationMode == .git)
        #expect(state.gitMode == .history)
    }

    @Test("Sidebar width policy clamps defaults, drags, and narrow windows")
    func widthPolicy() {
        let policy = DocumentNavigationSidebarWidthPolicy.self
        #expect(policy.clamp(policy.defaultWidth, containerWidth: 1_000) == 248)
        #expect(policy.clamp(100, containerWidth: 1_000) == policy.minimumWidth)
        #expect(policy.clamp(800, containerWidth: 1_000) == policy.maximumWidth)
        #expect(policy.clamp(400, containerWidth: 600) == 270)
        #expect(policy.clamp(400, containerWidth: 550) == 247)
    }
}

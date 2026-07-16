import Testing
@testable import FloralMDCore

@Suite("Document sidebar session state")
struct DocumentSidebarSessionStateTests {
    @Test("Every new document window starts with both sidebars collapsed")
    func initialState() {
        let state = DocumentSidebarSessionState()
        #expect(!state.isOutlineExpanded)
        #expect(!state.isNavigationExpanded)
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
}

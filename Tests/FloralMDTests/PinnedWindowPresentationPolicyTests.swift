import Foundation
import Testing
@testable import FloralMDCore

@Suite("Pinned window presentation policy")
struct PinnedWindowPresentationPolicyTests {
    @Test("Every pinned window uses the translucent background")
    func pinnedWindow() {
        #expect(opacity() == PinnedWindowPresentationPolicy.translucentBackgroundOpacity)
        #expect(opacity(isAlwaysOnTop: false) == 1)
        #expect(opacity(isFullScreen: true) == 1)
    }

    @Test("Accessibility display options force an opaque background")
    func accessibilityOverrides() {
        #expect(opacity(reduceTransparency: true) == 1)
        #expect(opacity(increaseContrast: true) == 1)
        #expect(opacity(reduceTransparency: true, increaseContrast: true) == 1)
    }

    private func opacity(isAlwaysOnTop: Bool = true,
                         isFullScreen: Bool = false,
                         reduceTransparency: Bool = false,
                         increaseContrast: Bool = false) -> CGFloat {
        PinnedWindowPresentationPolicy.backgroundOpacity(
            isAlwaysOnTop: isAlwaysOnTop,
            isFullScreen: isFullScreen,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }
}

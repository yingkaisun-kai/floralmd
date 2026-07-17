import Foundation
import Testing
@testable import FloralMDCore

@Suite("Pinned window presentation policy")
struct PinnedWindowPresentationPolicyTests {
    @Test("Ordinary document windows retain primary-window behavior")
    func windowModes() {
        #expect(presentation(.none) == WindowPinningPresentation(
            floatsAboveNormalWindows: false,
            joinsAllSpaces: false,
            joinsAllApplications: false,
            actsAsFullScreenAuxiliary: false,
            actsAsPrimaryWindow: true
        ))
        #expect(presentation(.currentSpace) == WindowPinningPresentation(
            floatsAboveNormalWindows: true,
            joinsAllSpaces: false,
            joinsAllApplications: false,
            actsAsFullScreenAuxiliary: false,
            actsAsPrimaryWindow: true
        ))
        #expect(presentation(.allSpaces) == WindowPinningPresentation(
            floatsAboveNormalWindows: false,
            joinsAllSpaces: false,
            joinsAllApplications: false,
            actsAsFullScreenAuxiliary: false,
            actsAsPrimaryWindow: true
        ))
    }

    @Test("All-Spaces auxiliary panel uses the proven cross-full-screen role")
    func auxiliaryPanel() {
        #expect(PinnedWindowPresentationPolicy.allSpacesAuxiliaryPresentation ==
            WindowPinningPresentation(
                floatsAboveNormalWindows: true,
                joinsAllSpaces: true,
                joinsAllApplications: false,
                actsAsFullScreenAuxiliary: true,
                actsAsPrimaryWindow: false
            ))
    }

    @Test("Each pinning mode has a stable titlebar status symbol")
    func statusSymbols() {
        #expect(WindowPinningMode.none.statusSymbolName == "pin.slash")
        #expect(WindowPinningMode.currentSpace.statusSymbolName == "pin.fill")
        #expect(WindowPinningMode.allSpaces.statusSymbolName == "globe")
    }

    @Test("Own full screen temporarily suspends every pinning mode")
    func ownFullScreenSuspension() {
        #expect(presentation(.currentSpace, suspended: true) == presentation(.none))
        #expect(presentation(.allSpaces, suspended: true) == presentation(.none))
    }

    @Test("Quick Capture defaults to current Space without downgrading all Spaces")
    func quickCaptureActivation() {
        #expect(quickCaptureMode(.none) == .currentSpace)
        #expect(quickCaptureMode(.currentSpace) == .currentSpace)
        #expect(quickCaptureMode(.allSpaces) == .allSpaces)
    }

    @Test("Every pinned window uses the translucent background")
    func pinnedWindow() {
        #expect(opacity() == PinnedWindowPresentationPolicy.translucentBackgroundOpacity)
        #expect(opacity(mode: .none) == 1)
        #expect(opacity(isFullScreen: true) == 1)
    }

    @Test("Accessibility display options force an opaque background")
    func accessibilityOverrides() {
        #expect(opacity(reduceTransparency: true) == 1)
        #expect(opacity(increaseContrast: true) == 1)
        #expect(opacity(reduceTransparency: true, increaseContrast: true) == 1)
    }

    private func presentation(_ mode: WindowPinningMode,
                              suspended: Bool = false) -> WindowPinningPresentation {
        PinnedWindowPresentationPolicy.windowPresentation(
            mode: mode,
            isSuspendedForOwnFullScreen: suspended
        )
    }

    private func quickCaptureMode(_ mode: WindowPinningMode) -> WindowPinningMode {
        PinnedWindowPresentationPolicy.quickCaptureActivationMode(currentMode: mode)
    }

    private func opacity(mode: WindowPinningMode = .currentSpace,
                         isFullScreen: Bool = false,
                         reduceTransparency: Bool = false,
                         increaseContrast: Bool = false) -> CGFloat {
        PinnedWindowPresentationPolicy.backgroundOpacity(
            mode: mode,
            isFullScreen: isFullScreen,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }
}

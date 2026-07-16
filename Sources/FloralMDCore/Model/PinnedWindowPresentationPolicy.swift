import Foundation

public enum WindowPinningMode: Equatable, Sendable {
    case none
    case currentSpace
    case allSpaces

    public var isPinned: Bool {
        self != .none
    }

    public var statusSymbolName: String {
        switch self {
        case .none: "pin.slash"
        case .currentSpace: "pin.fill"
        case .allSpaces: "globe"
        }
    }
}

public struct WindowPinningPresentation: Equatable, Sendable {
    public let floatsAboveNormalWindows: Bool
    public let joinsAllSpaces: Bool
    public let joinsAllApplications: Bool
    public let actsAsFullScreenAuxiliary: Bool
    public let actsAsPrimaryWindow: Bool

    public init(floatsAboveNormalWindows: Bool,
                joinsAllSpaces: Bool,
                joinsAllApplications: Bool,
                actsAsFullScreenAuxiliary: Bool,
                actsAsPrimaryWindow: Bool) {
        self.floatsAboveNormalWindows = floatsAboveNormalWindows
        self.joinsAllSpaces = joinsAllSpaces
        self.joinsAllApplications = joinsAllApplications
        self.actsAsFullScreenAuxiliary = actsAsFullScreenAuxiliary
        self.actsAsPrimaryWindow = actsAsPrimaryWindow
    }
}

/// Pure presentation decisions for pinned document windows.
public enum PinnedWindowPresentationPolicy {
    /// Keep enough of the background visible to reduce obstruction without
    /// weakening text, controls, or editor overlays.
    public static let translucentBackgroundOpacity: CGFloat = 0.88

    public static func windowPresentation(mode: WindowPinningMode,
                                          isSuspendedForOwnFullScreen: Bool)
    -> WindowPinningPresentation {
        guard !isSuspendedForOwnFullScreen else {
            return WindowPinningPresentation(
                floatsAboveNormalWindows: false,
                joinsAllSpaces: false,
                joinsAllApplications: false,
                actsAsFullScreenAuxiliary: false,
                actsAsPrimaryWindow: true
            )
        }

        return switch mode {
        case .none:
            WindowPinningPresentation(
                floatsAboveNormalWindows: false,
                joinsAllSpaces: false,
                joinsAllApplications: false,
                actsAsFullScreenAuxiliary: false,
                actsAsPrimaryWindow: true
            )
        case .currentSpace:
            WindowPinningPresentation(
                floatsAboveNormalWindows: true,
                joinsAllSpaces: false,
                joinsAllApplications: false,
                actsAsFullScreenAuxiliary: false,
                actsAsPrimaryWindow: true
            )
        case .allSpaces:
            WindowPinningPresentation(
                floatsAboveNormalWindows: true,
                joinsAllSpaces: true,
                joinsAllApplications: true,
                actsAsFullScreenAuxiliary: true,
                actsAsPrimaryWindow: false
            )
        }
    }

    /// Quick Capture must always return as a pinned entry surface, but reusing
    /// one that the user promoted to All Spaces must not silently downgrade it.
    public static func quickCaptureActivationMode(
        currentMode: WindowPinningMode
    ) -> WindowPinningMode {
        currentMode == .allSpaces ? .allSpaces : .currentSpace
    }

    /// Every pinned document uses the same translucent background, regardless
    /// of whether it is a normal document or Quick Capture.
    public static func backgroundOpacity(mode: WindowPinningMode,
                                         isFullScreen: Bool,
                                         reduceTransparency: Bool,
                                         increaseContrast: Bool) -> CGFloat {
        guard mode.isPinned,
              !isFullScreen,
              !reduceTransparency,
              !increaseContrast else {
            return 1
        }
        return translucentBackgroundOpacity
    }
}

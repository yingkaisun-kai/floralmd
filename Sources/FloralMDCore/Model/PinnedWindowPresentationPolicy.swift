import Foundation

/// Pure presentation decisions for pinned document windows.
public enum PinnedWindowPresentationPolicy {
    /// Keep enough of the background visible to reduce obstruction without
    /// weakening text, controls, or editor overlays.
    public static let translucentBackgroundOpacity: CGFloat = 0.88

    /// Every pinned document uses the same translucent background, regardless
    /// of whether it is a normal document or Quick Capture.
    public static func backgroundOpacity(isAlwaysOnTop: Bool,
                                         isFullScreen: Bool,
                                         reduceTransparency: Bool,
                                         increaseContrast: Bool) -> CGFloat {
        guard isAlwaysOnTop,
              !isFullScreen,
              !reduceTransparency,
              !increaseContrast else {
            return 1
        }
        return translucentBackgroundOpacity
    }
}

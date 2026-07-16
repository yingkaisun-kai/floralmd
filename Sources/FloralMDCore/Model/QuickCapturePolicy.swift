import Foundation

/// Pure decisions for the app shell's quick-capture entry point.
public enum QuickCapturePolicy {
    /// A focused writing surface that leaves room around the note while keeping
    /// the collapsed sidebar controls available.
    public static let compactWindowSize = CGSize(width: 550, height: 400)

    /// Reuse only the session's still-empty, still-untitled capture window.
    /// Once text exists (even before its debounced first save) the next global
    /// shortcut must create a new note instead of replacing the current thought.
    public static func shouldReuseWindow(isQuickCapture: Bool,
                                         hasFileURL: Bool,
                                         rawSource: String) -> Bool {
        isQuickCapture
            && !hasFileURL
            && rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Shrink around the window's current center and keep the result entirely
    /// inside the current display's usable frame.
    public static func compactWindowFrame(around currentFrame: CGRect,
                                          constrainedTo visibleFrame: CGRect) -> CGRect {
        let size = CGSize(
            width: min(compactWindowSize.width, visibleFrame.width),
            height: min(compactWindowSize.height, visibleFrame.height)
        )
        let centeredOrigin = CGPoint(
            x: currentFrame.midX - size.width / 2,
            y: currentFrame.midY - size.height / 2
        )
        let maximumOrigin = CGPoint(
            x: max(visibleFrame.minX, visibleFrame.maxX - size.width),
            y: max(visibleFrame.minY, visibleFrame.maxY - size.height)
        )
        return CGRect(
            origin: CGPoint(
                x: min(max(centeredOrigin.x, visibleFrame.minX), maximumOrigin.x),
                y: min(max(centeredOrigin.y, visibleFrame.minY), maximumOrigin.y)
            ),
            size: size
        )
    }
}

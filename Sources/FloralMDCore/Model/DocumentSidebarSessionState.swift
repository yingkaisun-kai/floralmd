import Foundation

public enum DocumentNavigationMode: Int, CaseIterable, Equatable, Sendable {
    case files
    case git
}

public enum DocumentGitMode: Int, CaseIterable, Equatable, Sendable {
    case changes
    case history
}

public enum DocumentNavigationSidebarWidthPolicy {
    public static let defaultWidth: CGFloat = 248
    public static let minimumWidth: CGFloat = 220
    public static let maximumWidth: CGFloat = 420
    public static let maximumWindowFraction: CGFloat = 0.45

    public static func clamp(_ width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let windowMaximum = max(minimumWidth, floor(containerWidth * maximumWindowFraction))
        return min(max(width, minimumWidth), min(maximumWidth, windowMaximum))
    }
}

/// Per-document-window visibility. New and restored document windows start
/// collapsed, while later user changes remain session-local and are never
/// reapplied by file-tree refreshes or other document updates.
public struct DocumentSidebarSessionState: Equatable, Sendable {
    public private(set) var isOutlineExpanded = false
    public private(set) var isNavigationExpanded = false
    public private(set) var navigationWidth = DocumentNavigationSidebarWidthPolicy.defaultWidth
    public private(set) var navigationMode: DocumentNavigationMode = .files
    public private(set) var gitMode: DocumentGitMode = .changes

    public init() {}

    public mutating func setOutlineExpanded(_ expanded: Bool) {
        isOutlineExpanded = expanded
    }

    public mutating func setNavigationExpanded(_ expanded: Bool) {
        isNavigationExpanded = expanded
    }

    public mutating func setNavigationWidth(_ width: CGFloat) {
        navigationWidth = min(max(width, DocumentNavigationSidebarWidthPolicy.minimumWidth),
                              DocumentNavigationSidebarWidthPolicy.maximumWidth)
    }

    public mutating func setNavigationMode(_ mode: DocumentNavigationMode) {
        navigationMode = mode
    }

    public mutating func setGitMode(_ mode: DocumentGitMode) {
        gitMode = mode
    }
}

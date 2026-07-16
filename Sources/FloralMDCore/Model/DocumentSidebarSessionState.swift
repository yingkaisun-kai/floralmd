import Foundation

/// Per-document-window visibility. New and restored document windows start
/// collapsed, while later user changes remain session-local and are never
/// reapplied by file-tree refreshes or other document updates.
public struct DocumentSidebarSessionState: Equatable, Sendable {
    public private(set) var isOutlineExpanded = false
    public private(set) var isNavigationExpanded = false

    public init() {}

    public mutating func setOutlineExpanded(_ expanded: Bool) {
        isOutlineExpanded = expanded
    }

    public mutating func setNavigationExpanded(_ expanded: Bool) {
        isNavigationExpanded = expanded
    }
}

import AppKit

/// Frames for the document window's sidebars and central editing surfaces.
/// Keeping this arithmetic in one value makes sidebar transitions and window
/// resizes use the same geometry.
public struct DocumentPaneLayout: Equatable {
    public static let documentControlSize: CGFloat = 32
    public static let documentControlInset: CGFloat = 14

    public let outlineSidebarFrame: NSRect
    public let editorFrame: NSRect
    public let outlineControlFrame: NSRect
    public let minimapFrame: NSRect
    public let statusFrame: NSRect
    public let navigationSidebarFrame: NSRect
    public let readFrame: NSRect

    public init(contentSize: NSSize,
                navigationSidebarWidth: CGFloat,
                outlineSidebarWidth: CGFloat,
                minimapWidth: CGFloat,
                statusBarHeight: CGFloat) {
        let editorOriginX = navigationSidebarWidth + outlineSidebarWidth
        let editorWidth = max(0, contentSize.width - editorOriginX - minimapWidth)
        outlineSidebarFrame = NSRect(x: navigationSidebarWidth, y: 0,
                                     width: outlineSidebarWidth,
                                     height: contentSize.height)
        editorFrame = NSRect(x: editorOriginX, y: 0,
                             width: editorWidth, height: contentSize.height)
        outlineControlFrame = NSRect(
            x: editorFrame.minX + Self.documentControlInset,
            y: max(0, contentSize.height
                - Self.documentControlInset
                - Self.documentControlSize),
            width: Self.documentControlSize,
            height: Self.documentControlSize
        )
        minimapFrame = NSRect(x: editorFrame.maxX, y: 0,
                              width: minimapWidth, height: contentSize.height)
        statusFrame = NSRect(x: editorOriginX, y: 0,
                             width: editorWidth, height: statusBarHeight)
        navigationSidebarFrame = NSRect(x: 0, y: 0,
                                        width: navigationSidebarWidth,
                                        height: contentSize.height)
        readFrame = NSRect(x: editorOriginX, y: 0,
                           width: editorWidth + minimapWidth,
                           height: contentSize.height)
    }
}

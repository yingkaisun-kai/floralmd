import AppKit
import Testing
@testable import FloralMDCore

@Suite("Document pane layout")
struct DocumentPaneLayoutTests {
    @Test("Collapsing the file sidebar shifts the outline and editor back to the left")
    func fileSidebarCollapseAndRestore() {
        let contentSize = NSSize(width: 1_000, height: 600)
        let expanded = DocumentPaneLayout(contentSize: contentSize,
                                          navigationSidebarWidth: 230,
                                          outlineSidebarWidth: 320,
                                          minimapWidth: 72,
                                          statusBarHeight: 22)
        let collapsed = DocumentPaneLayout(contentSize: contentSize,
                                           navigationSidebarWidth: 0,
                                           outlineSidebarWidth: 320,
                                           minimapWidth: 72,
                                           statusBarHeight: 22)
        let reopened = DocumentPaneLayout(contentSize: contentSize,
                                          navigationSidebarWidth: 230,
                                          outlineSidebarWidth: 320,
                                          minimapWidth: 72,
                                          statusBarHeight: 22)

        #expect(collapsed.editorFrame.width - expanded.editorFrame.width == 230)
        #expect(expanded.outlineSidebarFrame.minX == 230)
        #expect(collapsed.outlineSidebarFrame.minX == 0)
        #expect(collapsed.navigationSidebarFrame.width == 0)
        #expect(collapsed.navigationSidebarFrame.minX == 0)
        #expect(reopened == expanded)
    }

    @Test("Read mode and the status bar follow the same sidebar geometry")
    func companionFramesFollowEditor() {
        let layout = DocumentPaneLayout(contentSize: NSSize(width: 900, height: 500),
                                        navigationSidebarWidth: 0,
                                        outlineSidebarWidth: 0,
                                        minimapWidth: 72,
                                        statusBarHeight: 22)

        #expect(layout.statusFrame.minX == layout.editorFrame.minX)
        #expect(layout.statusFrame.width == layout.editorFrame.width)
        #expect(layout.readFrame.width == layout.editorFrame.width + layout.minimapFrame.width)
        #expect(layout.readFrame.maxX == 900)
        #expect(layout.outlineControlFrame.minX
            == layout.editorFrame.minX + DocumentPaneLayout.documentControlInset)
        #expect(layout.outlineControlFrame.maxY
            == 500 - DocumentPaneLayout.documentControlInset)
    }

    @Test("Collapsed sidebars reserve no content rail with or without a minimap")
    func collapsedSidebarsReclaimAllContentWidth() {
        let contentSize = NSSize(width: 800, height: 560)
        for minimapWidth in [CGFloat(0), CGFloat(72)] {
            let layout = DocumentPaneLayout(contentSize: contentSize,
                                            navigationSidebarWidth: 0,
                                            outlineSidebarWidth: 0,
                                            minimapWidth: minimapWidth,
                                            statusBarHeight: 22)

            #expect(layout.navigationSidebarFrame == NSRect(x: 0, y: 0,
                                                            width: 0, height: 560))
            #expect(layout.outlineSidebarFrame == NSRect(x: 0, y: 0,
                                                         width: 0, height: 560))
            #expect(layout.editorFrame.maxX + layout.minimapFrame.width == contentSize.width)
            #expect(layout.outlineControlFrame.size == NSSize(
                width: DocumentPaneLayout.documentControlSize,
                height: DocumentPaneLayout.documentControlSize
            ))
        }
    }

    @Test("The file sidebar alone stays at the left edge and precedes the editor")
    func fileSidebarOnly() {
        let layout = DocumentPaneLayout(contentSize: NSSize(width: 900, height: 500),
                                        navigationSidebarWidth: 230,
                                        outlineSidebarWidth: 0,
                                        minimapWidth: 0,
                                        statusBarHeight: 22)

        #expect(layout.navigationSidebarFrame == NSRect(x: 0, y: 0,
                                                        width: 230, height: 500))
        #expect(layout.outlineSidebarFrame == NSRect(x: 230, y: 0,
                                                     width: 0, height: 500))
        #expect(layout.editorFrame.minX == 230)
        #expect(layout.editorFrame.maxX == 900)
        #expect(layout.outlineControlFrame.minX
            == 230 + DocumentPaneLayout.documentControlInset)
    }
}

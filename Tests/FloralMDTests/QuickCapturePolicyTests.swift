import Foundation
import Testing
@testable import FloralMDCore

@Suite("Quick capture policy")
struct QuickCapturePolicyTests {
    @Test("Compact capture uses the document window minimum")
    func compactSizeMatchesWindowMinimum() {
        #expect(QuickCapturePolicy.compactWindowSize == CGSize(width: 550, height: 400))
    }

    @Test("Reuses only a blank untitled quick-capture window")
    func reuseBlankUntitledCapture() {
        #expect(QuickCapturePolicy.shouldReuseWindow(
            isQuickCapture: true, hasFileURL: false, rawSource: "  \n"
        ))
        #expect(!QuickCapturePolicy.shouldReuseWindow(
            isQuickCapture: false, hasFileURL: false, rawSource: ""
        ))
        #expect(!QuickCapturePolicy.shouldReuseWindow(
            isQuickCapture: true, hasFileURL: true, rawSource: ""
        ))
        #expect(!QuickCapturePolicy.shouldReuseWindow(
            isQuickCapture: true, hasFileURL: false, rawSource: "new thought"
        ))
    }

    @Test("Compact capture stays centered when there is room")
    func compactFramePreservesCenter() {
        let current = CGRect(x: 100, y: 80, width: 1_000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let compact = QuickCapturePolicy.compactWindowFrame(
            around: current,
            constrainedTo: visible
        )

        #expect(compact.size == QuickCapturePolicy.compactWindowSize)
        #expect(compact.midX == current.midX)
        #expect(compact.midY == current.midY)
    }

    @Test("Compact capture is clamped to the display's usable frame")
    func compactFrameStaysVisible() {
        let current = CGRect(x: 1_300, y: 760, width: 900, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let compact = QuickCapturePolicy.compactWindowFrame(
            around: current,
            constrainedTo: visible
        )

        #expect(visible.contains(compact))
        #expect(compact.maxX == visible.maxX)
        #expect(compact.maxY == visible.maxY)
    }
}

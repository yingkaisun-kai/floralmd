// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit

// MARK: - Content width (centered reading column)
//
// The text column has a physical maximum width (set in cm in Settings and
// converted to points using the display's real PPI). Windows wider than the
// cap get symmetric side margins that center the column; narrower windows
// fill edge-to-edge as usual. This is CSS `max-width` semantics: the cap is
// an absolute physical size, not a fraction of the window or the screen, so
// the column doesn't widen when you make the window bigger.

extension EditorTextView {

    /// Padding applied on each side of the text column at all window sizes.
    static let contentBaseInset: CGFloat = 44

    /// The symmetric horizontal inset for a given view width and max-column width.
    /// `maxContentWidth == .greatestFiniteMagnitude` → base inset only (fills the window).
    /// When the window is too narrow to fit `maxContentWidth`, the column also fills.
    public static func horizontalInset(viewWidth: CGFloat, maxContentWidth: CGFloat) -> CGFloat {
        let available = viewWidth - 2 * contentBaseInset
        guard available > maxContentWidth else { return contentBaseInset }
        return contentBaseInset + (available - maxContentWidth) / 2
    }

    /// Recomputes the horizontal text inset from the current bounds + max-column cap,
    /// preserving the vertical inset. Usually no recompose — only the inset
    /// changes and TextKit 2 reflows wrapped text on its own. Tables and image
    /// overlays are exceptions: their fitted widths are baked into styled
    /// attributes at render time, so they must be restyled against the new
    /// content width. Restyling also invalidates every table-row fragment as
    /// one unit; otherwise a compact-window resize can leave rows drawn from
    /// different layout generations and visibly shift one row's grid.
    public func updateContentInset() {
        let target = Self.horizontalInset(viewWidth: bounds.width,
                                          maxContentWidth: maxContentWidthPoints)
        guard abs(textContainerInset.width - target) > 0.5 else { return }
        textContainerInset = NSSize(width: target, height: textContainerInset.height)

        let widthSensitiveBlocks = IndexSet(blocks.indices.filter {
            blocks[$0].kind == .table || blocks[$0].content.contains("![")
        })
        guard !widthSensitiveBlocks.isEmpty else { return }
        for idx in widthSensitiveBlocks { blocks[idx].isStyled = false }
        recomposeDirty(widthSensitiveBlocks,
                       cursorInRaw: currentCursorInRaw(),
                       settingSelection: true)
    }

    /// Recompute the centered inset as the view width changes (window resize).
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContentInset()
    }
}

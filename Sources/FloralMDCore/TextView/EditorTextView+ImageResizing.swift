import AppKit

private let imageResizeHandleSize: CGFloat = 12
private let imageResizeChromeOutset: CGFloat = 2

func imageResizeHandleRect(for frame: CGRect) -> CGRect {
    // Keep the handle inside the image fragment. Adjacent text can claim points
    // outside the fragment before the editor's resize hit test receives them.
    CGRect(x: frame.maxX - imageResizeHandleSize - 3,
           y: frame.maxY - imageResizeHandleSize - 3,
           width: imageResizeHandleSize,
           height: imageResizeHandleSize)
}

final class ImageResizeChromeView: NSView {
    private var accentColor: NSColor = .controlAccentColor
    private var editorBackgroundColor: NSColor = .textBackgroundColor
    private var previewImage: NSImage?
    private var isResizing = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(around imageFrame: CGRect, image: NSImage? = nil,
              accentColor: NSColor, backgroundColor: NSColor,
              isResizing: Bool) {
        frame = imageFrame.insetBy(dx: -imageResizeChromeOutset,
                                   dy: -imageResizeChromeOutset)
        previewImage = image
        self.accentColor = accentColor
        editorBackgroundColor = backgroundColor
        self.isResizing = isResizing
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let imageRect = bounds.insetBy(dx: imageResizeChromeOutset,
                                       dy: imageResizeChromeOutset)
        if let previewImage {
            previewImage.draw(
                in: imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.medium]
            )
        }
        let lineWidth: CGFloat = isResizing ? 2 : 1.5
        accentColor.withAlphaComponent(isResizing ? 0.95 : 0.82).setStroke()
        let outline = NSBezierPath(rect: imageRect.insetBy(dx: -lineWidth / 2,
                                                           dy: -lineWidth / 2))
        outline.lineWidth = lineWidth
        if isResizing { outline.setLineDash([5, 4], count: 2, phase: 0) }
        outline.stroke()

        let handle = imageResizeHandleRect(for: imageRect)
        editorBackgroundColor.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
        accentColor.setStroke()
        let handleOutline = NSBezierPath(
            roundedRect: handle.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 1.5,
            yRadius: 1.5
        )
        handleOutline.lineWidth = 1.5
        handleOutline.stroke()
    }
}

struct ImageOverlayHit {
    let anchor: Int
    let sourceRange: NSRange
    let frame: CGRect
    let overlay: FragmentOverlay
}

struct ImageResizeSession {
    let hit: ImageOverlayHit
    let startPoint: CGPoint
    let selectionBefore: NSRange
    var previewFrame: CGRect
    var didMove = false
}

extension EditorTextView {
    private static let minimumImageWidth: CGFloat = 48

    private func showImageResizeChrome(around frame: CGRect, image: NSImage? = nil,
                                       isResizing: Bool) {
        imageResizeChromeView.show(
            around: frame,
            image: image,
            accentColor: accentColor,
            backgroundColor: backgroundColor,
            isResizing: isResizing
        )
    }

    func updateImageResizeHover(at point: CGPoint) {
        guard imageResizeSession == nil else { return }
        let oldHit = hoveredImageOverlay
        let newHit = imageOverlayHit(at: point)
        hoveredImageOverlay = newHit
        if let newHit {
            // Refresh on every mouse move, even when the overlay identity is
            // unchanged: scrolling or a TextKit relayout can move its frame.
            showImageResizeChrome(around: newHit.frame, isResizing: false)
        } else {
            imageResizeChromeView.hide()
        }
        if oldHit?.overlay !== newHit?.overlay {
            window?.invalidateCursorRects(for: self)
        }
    }

    func clearImageResizeHover() {
        guard imageResizeSession == nil, hoveredImageOverlay != nil else { return }
        hoveredImageOverlay = nil
        imageResizeChromeView.hide()
        window?.invalidateCursorRects(for: self)
    }

    func beginImageResizeIfNeeded(with event: NSEvent) -> Bool {
        guard viewMode == .edit else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = imageOverlayHit(at: point),
              imageResizeHandleRect(for: hit.frame).insetBy(dx: -3, dy: -3).contains(point)
        else { return false }

        imageResizeSession = ImageResizeSession(
            hit: hit,
            startPoint: point,
            selectionBefore: selectedRange(),
            previewFrame: hit.frame
        )
        hit.overlay.suppressesImageDrawing = true
        showImageResizeChrome(around: hit.frame, image: hit.overlay.image,
                              isResizing: true)
        hoveredImageOverlay = hit
        // Clear the fragment copy once before the drag starts. Every following
        // frame is a lightweight foreground-view resize and does not wait for
        // TextKit's rendering-surface cache.
        setNeedsDisplay(hit.frame.insetBy(dx: -8, dy: -8))
        displayIfNeeded()
        window?.invalidateCursorRects(for: self)
        return true
    }

    func updateImageResize(with event: NSEvent) -> Bool {
        updateImageResize(to: convert(event.locationInWindow, from: nil))
    }

    func updateImageResize(to point: CGPoint) -> Bool {
        guard var session = imageResizeSession else { return false }
        let proposed = session.hit.frame.width + point.x - session.startPoint.x
        let maxWidth = max(1, availableContentWidth)
        let minWidth = min(Self.minimumImageWidth, maxWidth)
        let width = min(maxWidth, max(minWidth, proposed))
        let ratio = session.hit.frame.height / max(1, session.hit.frame.width)
        session.previewFrame.size = CGSize(width: width, height: width * ratio)
        session.didMove = session.didMove || abs(width - session.hit.frame.width) >= 1
        imageResizeSession = session
        showImageResizeChrome(around: session.previewFrame,
                              image: session.hit.overlay.image,
                              isResizing: true)
        return true
    }

    func finishImageResize(with event: NSEvent) -> Bool {
        guard var session = imageResizeSession else { return false }
        _ = updateImageResize(with: event)
        session = imageResizeSession ?? session
        session.hit.overlay.suppressesImageDrawing = false
        imageResizeChromeView.hide()
        imageResizeSession = nil
        hoveredImageOverlay = nil
        setNeedsDisplay(session.hit.frame.union(session.previewFrame).insetBy(dx: -8, dy: -8))
        window?.invalidateCursorRects(for: self)

        guard session.didMove else { return true }
        _ = setImageWidth(
            atRawOffset: session.hit.anchor,
            width: max(1, Int(session.previewFrame.width.rounded())),
            preserving: session.selectionBefore
        )
        return true
    }

    /// Resolves a rendered image overlay at `point` back to the exact raw
    /// Markdown image span that owns it. Other overlay kinds (math, bullets,
    /// placeholders) are deliberately not interactive.
    func imageOverlayHit(at point: CGPoint) -> ImageOverlayHit? {
        guard let tlm = textLayoutManager else { return nil }
        let textPoint = CGPoint(x: point.x - textContainerOrigin.x,
                                y: point.y - textContainerOrigin.y)
        let directFragment = tlm.textLayoutFragment(for: textPoint)
            as? DecoratedTextLayoutFragment
        if let directFragment,
           let hit = imageOverlayHit(in: directFragment, at: textPoint, using: tlm) {
            return hit
        }

        // An image grows upward from its one-line Markdown anchor, often far
        // outside that fragment's layout frame. TextKit's point lookup then
        // returns the paragraph visually behind the image (or nil), so scan
        // the already-laid viewport fragments and test their actual overlay
        // rectangles. Do not use `.ensuresLayout` here: this runs on every
        // mouse-move and must never lay out the document just for hover UI.
        let viewport = tlm.textViewportLayoutController.viewportRange
        let start = viewport?.location ?? tlm.documentRange.location
        let endOffset = viewport.map {
            tlm.offset(from: tlm.documentRange.location, to: $0.endLocation)
        } ?? Int.max
        var found: ImageOverlayHit?
        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard let fragment = fragment as? DecoratedTextLayoutFragment,
                  let paragraphStart = fragment.textElement?.elementRange?.location
            else { return true }
            if tlm.offset(from: tlm.documentRange.location, to: paragraphStart) > endOffset {
                return false
            }
            guard fragment !== directFragment else { return true }
            found = self.imageOverlayHit(in: fragment, at: textPoint, using: tlm)
            return found == nil
        }
        return found
    }

    private func imageOverlayHit(in fragment: DecoratedTextLayoutFragment,
                                 at textPoint: CGPoint,
                                 using tlm: NSTextLayoutManager) -> ImageOverlayHit? {
        guard let paragraphStart = fragment.textElement?.elementRange?.location else {
            return nil
        }
        let fragmentFrame = fragment.layoutFragmentFrame
        let localPoint = CGPoint(x: textPoint.x - fragmentFrame.minX,
                                 y: textPoint.y - fragmentFrame.minY)

        for (offset, overlay) in fragment.overlays.reversed()
        where overlay.role == .resizableImage {
            guard overlay.image != nil,
                  let localRect = fragment.overlayRect(anchorOffset: offset, overlay: overlay),
                  localRect.contains(localPoint)
                    || imageResizeHandleRect(for: localRect)
                        .insetBy(dx: -3, dy: -3).contains(localPoint)
            else { continue }
            let anchor = tlm.offset(from: tlm.documentRange.location, to: paragraphStart) + offset
            guard let source = markdownImageSource(atRawOffset: anchor) else { continue }
            let frame = localRect.offsetBy(dx: fragmentFrame.minX + textContainerOrigin.x,
                                           dy: fragmentFrame.minY + textContainerOrigin.y)
            return ImageOverlayHit(anchor: anchor, sourceRange: source.range,
                                   frame: frame, overlay: overlay)
        }
        return nil
    }

    func setImageWidth(atRawOffset offset: Int, width: Int,
                       preserving selection: NSRange? = nil) -> Bool {
        guard let source = markdownImageSource(atRawOffset: offset),
              let replacement = ImageReference.markdownBySettingWidth(source.markdown, width: width)
        else { return false }
        let oldSelection = selection ?? selectedRange()
        let delta = (replacement as NSString).length - source.range.length
        let mappedSelection: NSRange
        if oldSelection.location >= source.range.upperBound {
            mappedSelection = NSRange(location: oldSelection.location + delta,
                                      length: oldSelection.length)
        } else {
            mappedSelection = oldSelection
        }
        applyFormattingEdit(rawRange: source.range, replacement: replacement,
                            select: mappedSelection)
        return true
    }

    private func markdownImageSource(atRawOffset offset: Int)
        -> (range: NSRange, markdown: String)? {
        guard let blockIndex = blockIndexForRawOffset(offset), blockIndex < blocks.count else {
            return nil
        }
        let block = blocks[blockIndex]
        let localOffset = offset - block.range.location
        guard let span = SyntaxHighlighter.parse(
            block.content,
            linkDefinitions: linkDefState.defsText,
            features: markdownFeatures
        ).first(where: {
            guard $0.fullRange.location == localOffset else { return false }
            if case .image = $0.kind { return true }
            return false
        }) else { return nil }
        let ns = block.content as NSString
        guard span.fullRange.location < ns.length,
              ns.character(at: span.fullRange.location) == 0x21 else { return nil }
        let range = NSRange(location: block.range.location + span.fullRange.location,
                            length: span.fullRange.length)
        return (range, ns.substring(with: span.fullRange))
    }
}

import AppKit

struct CodeBlockHit {
    let presentation: CodeBlockPresentation
    let frame: CGRect
    let controlY: CGFloat
}

private struct CodeBlockFragmentGroup {
    let presentation: CodeBlockPresentation
    var minY: CGFloat
    var maxY: CGFloat
    var firstSafeControlY: CGFloat?
}

struct CodeBlockLanguageOverlayItem {
    let label: String
    let frame: CGRect
}

/// Foreground, event-transparent language labels for visible fenced blocks.
/// A fragment-local label can extend into the next compact code row, whose
/// background is drawn later and covers it. Drawing once above TextKit keeps
/// the Read-mode block anchor intact without adding layout height.
final class CodeBlockLanguageOverlayView: NSView {
    weak var editor: EditorTextView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func visibleItems() -> [CodeBlockLanguageOverlayItem] {
        guard let editor, editor.viewMode == .edit,
              let tlm = editor.textLayoutManager,
              let container = tlm.textContainer else { return [] }

        let viewport = tlm.textViewportLayoutController.viewportRange
        let start = viewport?.location ?? tlm.documentRange.location
        let origin = editor.textContainerOrigin
        let visibleMaxY = editor.visibleRect.maxY
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var items: [CodeBlockLanguageOverlayItem] = []
        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let fragmentFrame = fragment.layoutFragmentFrame
            if origin.y + fragmentFrame.minY > visibleMaxY { return false }
            guard let decorated = fragment as? DecoratedTextLayoutFragment,
                  let label = decorated.codeBlockLanguageLabel,
                  !label.isEmpty else { return true }
            let textSize = (label as NSString).size(withAttributes: [.font: font])
            guard var frame = CodeBlockChromeLayout.languageLabelRect(
                blockLeft: origin.x - CodeBlockChromeLayout.backgroundOutset,
                blockWidth: container.size.width + 2 * CodeBlockChromeLayout.backgroundOutset,
                textSize: textSize
            ) else { return true }
            frame.origin.y += origin.y + fragmentFrame.minY
            items.append(CodeBlockLanguageOverlayItem(label: label, frame: frame))
            return true
        }
        return items
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for item in visibleItems() where item.frame.intersects(dirtyRect) {
            NSColor.tertiaryLabelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: item.frame, xRadius: 4, yRadius: 4).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: item.label, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]).draw(with: item.frame.insetBy(dx: 6, dy: 4),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// Foreground hover chrome for a fenced code block. Only the trailing button
/// region participates in hit-testing; the transparent feedback/spacing area
/// passes events through to NSTextView so selection and editing stay native.
final class CodeBlockControlView: NSView {
    var onCopy: (() -> Void)?
    var onFeedbackEnded: (() -> Void)?

    private(set) var isShowingFeedback = false
    private var isHovered = false
    private var strings: ReadModeCopyStrings = .english

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    var buttonRect: CGRect {
        CGRect(x: bounds.maxX - CodeBlockChromeLayout.controlHeight,
               y: 0,
               width: CodeBlockChromeLayout.controlHeight,
               height: CodeBlockChromeLayout.controlHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, buttonRect.contains(point) else { return nil }
        return self
    }

    func containsButton(editorPoint: CGPoint) -> Bool {
        guard !isHidden, let superview else { return false }
        return buttonRect.contains(convert(editorPoint, from: superview))
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(buttonRect, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard buttonRect.contains(point) else { return }
        onCopy?()
    }

    override func accessibilityPerformPress() -> Bool {
        onCopy?()
        return true
    }

    func show(frame: CGRect, strings: ReadModeCopyStrings) {
        self.frame = frame
        self.strings = strings
        isHovered = true
        isHidden = false
        setAccessibilityRole(.button)
        setAccessibilityLabel(strings.copyCode)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func updateStrings(_ strings: ReadModeCopyStrings) {
        self.strings = strings
        setAccessibilityLabel(isShowingFeedback ? strings.copied : strings.copyCode)
        needsDisplay = true
    }

    func hideUnlessShowingFeedback() {
        isHovered = false
        if !isShowingFeedback { isHidden = true }
    }

    func showCopiedFeedback(duration: TimeInterval = 1.6) {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(endCopiedFeedback),
            object: nil
        )
        isShowingFeedback = true
        isHidden = false
        setAccessibilityLabel(strings.copied)
        needsDisplay = true
        perform(#selector(endCopiedFeedback), with: nil, afterDelay: duration,
                inModes: [.common])
    }

    func cancelCopiedFeedback() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(endCopiedFeedback),
            object: nil
        )
        guard isShowingFeedback else { return }
        isShowingFeedback = false
        setAccessibilityLabel(strings.copyCode)
        needsDisplay = true
    }

    @objc private func endCopiedFeedback() {
        isShowingFeedback = false
        setAccessibilityLabel(strings.copyCode)
        needsDisplay = true
        if !isHovered { isHidden = true }
        onFeedbackEnded?()
    }

    private var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var buttonBackgroundColor: NSColor {
        NSColor(calibratedWhite: usesDarkAppearance ? 0.158 : 0.962, alpha: 0.98)
    }

    private var buttonBorderColor: NSColor {
        usesDarkAppearance
            ? NSColor(calibratedWhite: 1, alpha: 0.14)
            : NSColor(calibratedWhite: 0, alpha: 0.12)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isShowingFeedback {
            let feedbackRect = CGRect(x: 0, y: 1,
                                      width: max(0, buttonRect.minX - 4),
                                      height: bounds.height - 2)
            buttonBackgroundColor.setFill()
            NSBezierPath(roundedRect: feedbackRect, xRadius: 5, yRadius: 5).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: strings.copied, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]).draw(with: feedbackRect.insetBy(dx: 3, dy: 3),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.set()
        buttonBackgroundColor.setFill()
        buttonBorderColor.setStroke()
        let buttonPath = NSBezierPath(roundedRect: buttonRect.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 6, yRadius: 6)
        buttonPath.lineWidth = 1
        buttonPath.fill()
        NSShadow().set()
        buttonPath.stroke()

        let iconColor = isShowingFeedback ? NSColor.systemGreen : NSColor.secondaryLabelColor
        iconColor.setStroke()
        if isShowingFeedback {
            let path = NSBezierPath()
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: buttonRect.minX + 6, y: buttonRect.midY))
            path.line(to: CGPoint(x: buttonRect.minX + 9.5, y: buttonRect.midY + 3.5))
            path.line(to: CGPoint(x: buttonRect.maxX - 5.5, y: buttonRect.midY - 4))
            path.stroke()
        } else {
            let iconRects = CodeBlockChromeLayout.copyIconRects(in: buttonRect)
            let back = NSBezierPath(roundedRect: iconRects.back,
                                    xRadius: 1.75, yRadius: 1.75)
            back.lineWidth = 1.5
            back.stroke()
            let front = NSBezierPath(roundedRect: iconRects.front,
                                     xRadius: 1.75, yRadius: 1.75)
            front.lineWidth = 1.5
            front.stroke()
        }
    }

}

extension EditorTextView {
    /// Finds a fenced-code surface using only fragments TextKit 2 has already
    /// laid out. Hover must never force off-screen layout or perturb scrolling.
    func codeBlockHit(at point: CGPoint) -> CodeBlockHit? {
        guard viewMode == .edit,
              let tlm = textLayoutManager,
              let container = tlm.textContainer else { return nil }

        let textPoint = CGPoint(x: point.x - textContainerOrigin.x,
                                y: point.y - textContainerOrigin.y)
        let viewport = tlm.textViewportLayoutController.viewportRange
        let start = viewport?.location ?? tlm.documentRange.location
        var grouped: [CodeBlockFragmentGroup] = []
        let buttonMinX = container.size.width - CodeBlockChromeLayout.trailingInset
            - CodeBlockChromeLayout.controlHeight

        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > textPoint.y + bounds.height { return false }
            guard let decorated = fragment as? DecoratedTextLayoutFragment,
                  let presentation = decorated.codeBlockPresentation else { return true }
            let firstLineMaxX = decorated.textLineFragments.first?.typographicBounds.maxX
                ?? CGFloat.greatestFiniteMagnitude
            let safeY = firstLineMaxX <= buttonMinX - 4 ? frame.minY + 1 : nil
            if let index = grouped.firstIndex(where: { $0.presentation === presentation }) {
                grouped[index].minY = min(grouped[index].minY, frame.minY)
                grouped[index].maxY = max(grouped[index].maxY, frame.maxY)
                if grouped[index].firstSafeControlY == nil {
                    grouped[index].firstSafeControlY = safeY
                }
            } else {
                grouped.append(CodeBlockFragmentGroup(
                    presentation: presentation,
                    minY: frame.minY,
                    maxY: frame.maxY,
                    firstSafeControlY: safeY
                ))
            }
            return true
        }

        let outset = CodeBlockChromeLayout.backgroundOutset
        let column = CGRect(x: -outset, y: 0,
                            width: container.size.width + 2 * outset, height: 0)
        for item in grouped {
            let local = CGRect(x: column.minX, y: item.minY,
                               width: column.width, height: item.maxY - item.minY)
            guard local.contains(textPoint) else { continue }
            let controlY: CGFloat
            if item.presentation.isActive {
                guard let safeY = item.firstSafeControlY else { continue }
                controlY = safeY
            } else {
                // Match Read mode's `top: 8px`; unlike line-relative placement,
                // this remains fixed when editor line spacing changes.
                controlY = item.minY + 8
            }
            return CodeBlockHit(
                presentation: item.presentation,
                frame: local.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y),
                controlY: controlY + textContainerOrigin.y
            )
        }
        return nil
    }

    func updateCodeBlockControlHover(at point: CGPoint) {
        guard let hit = codeBlockHit(at: point) else {
            hoveredCodeBlock = nil
            codeBlockControlView.hideUnlessShowingFeedback()
            return
        }
        if let previous = hoveredCodeBlock,
           previous.presentation !== hit.presentation {
            codeBlockControlView.cancelCopiedFeedback()
        }
        hoveredCodeBlock = hit
        let frame = CGRect(
            x: hit.frame.maxX - CodeBlockChromeLayout.trailingInset
                - CodeBlockChromeLayout.controlWidth,
            y: hit.controlY,
            width: CodeBlockChromeLayout.controlWidth,
            height: CodeBlockChromeLayout.controlHeight
        )
        codeBlockControlView.show(frame: frame, strings: codeBlockCopyStrings)
    }

    func clearCodeBlockControlHover() {
        hoveredCodeBlock = nil
        codeBlockControlView.hideUnlessShowingFeedback()
    }

    func copyHoveredCodeBlock() {
        guard let hit = hoveredCodeBlock else { return }
        copyCodeBlock(hit.presentation)
    }

    func handleCodeBlockControlClick(at point: CGPoint) -> Bool {
        guard codeBlockControlView.containsButton(editorPoint: point) else { return false }
        copyHoveredCodeBlock()
        return true
    }

    /// Clipboard-only action: it intentionally does not begin text editing,
    /// restyle storage, change selection, or make any view first responder.
    func copyCodeBlock(_ presentation: CodeBlockPresentation) {
        let selectionBefore = selectedRange()
        let responderBefore = window?.firstResponder
        codeBlockCopyPasteboard.clearContents()
        guard codeBlockCopyPasteboard.setString(presentation.code, forType: .string) else { return }
        codeBlockControlView.showCopiedFeedback()
        if selectedRange() != selectionBefore { setSelectedRange(selectionBefore) }
        if let responderBefore, window?.firstResponder !== responderBefore {
            window?.makeFirstResponder(responderBefore)
        }
    }
}

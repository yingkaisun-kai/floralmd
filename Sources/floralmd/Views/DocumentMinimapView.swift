import AppKit
import FloralMDCore

/// Lightweight semantic overview of a Markdown document. It deliberately
/// draws structure bars rather than tiny glyphs: headings, lists, quotes,
/// code-ish lines, Git changes, the caret line, and the visible viewport.
final class DocumentMinimapView: NSView {
    static let width: CGFloat = 78

    weak var editor: EditorTextView?
    weak var scrollView: NSScrollView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// The document window allows dragging by its background. This interactive
    /// strip must opt out or a minimap drag moves the entire window as well.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor
        toolTip = AppCopy.text("Document overview — click or drag to scroll",
                               "文档缩略图——单击或拖动以滚动")
        setAccessibilityLabel(AppCopy.text("Document minimap", "文档缩略图"))
    }

    required init?(coder: NSCoder) { nil }

    func refresh() { needsDisplay = true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let editor else { return }
        let lines = editor.rawSource.components(separatedBy: "\n")
        guard !lines.isEmpty, bounds.height > 0 else { return }

        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        let usableHeight = max(1, bounds.height - 8)
        let step = usableHeight / CGFloat(max(1, lines.count))
        let strokeHeight = max(0.7, min(2, step * 0.55))
        let maxBarWidth = max(8, bounds.width - 12)
        let changes = editor.gitChangeSet
        let cursorLine = lineIndex(in: editor.rawSource,
                                   utf16Offset: editor.selectedRange().location)

        var isInsideCodeFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let y = 4 + CGFloat(index) * step
            if let change = changes.lines[index] {
                let color: NSColor = switch change {
                case .added: .systemGreen
                case .modified: .systemBlue
                }
                color.withAlphaComponent(0.9).setFill()
                NSRect(x: 2, y: y, width: 2, height: max(1.5, strokeHeight)).fill()
            }
            guard !trimmed.isEmpty else { continue }
            let leading = line.prefix { $0 == " " || $0 == "\t" }.count
            let x = min(maxBarWidth * 0.35, 5 + CGFloat(leading) * 1.45)
            let visibleLength = max(3, trimmed.utf16.count)
            let width = min(maxBarWidth - x + 4,
                            max(4, CGFloat(visibleLength) * 0.42))

            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            color(for: trimmed, isInsideCodeFence: isInsideCodeFence || isFence).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width,
                                             height: strokeHeight),
                         xRadius: strokeHeight / 2, yRadius: strokeHeight / 2).fill()

            if index == cursorLine {
                NSColor.controlAccentColor.setFill()
                NSRect(x: max(2, x - 3), y: y - 0.5,
                       width: min(bounds.width - x + 1, width + 5),
                       height: max(1.5, strokeHeight + 1)).fill()
            }
            if isFence { isInsideCodeFence.toggle() }
        }
        NSColor.systemRed.withAlphaComponent(0.9).setFill()
        for boundary in changes.deletionBoundaries {
            let y = 4 + CGFloat(boundary) * step
            NSRect(x: 2, y: y - 1, width: 5, height: 2).fill()
        }

        drawViewportIndicator()
    }

    override func mouseDown(with event: NSEvent) { scroll(to: event) }
    override func mouseDragged(with event: NSEvent) { scroll(to: event) }

    private func scroll(to event: NSEvent) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let visibleHeight = scrollView.contentView.bounds.height
        let maxY = max(0, document.bounds.height - visibleHeight)
        let fraction = max(0, min(1, convert(event.locationInWindow, from: nil).y
                                  / max(1, bounds.height)))
        let target = max(0, min(maxY, fraction * document.bounds.height - visibleHeight / 2))
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x,
                                                  y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsDisplay = true
    }

    private func drawViewportIndicator() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let documentHeight = max(1, document.bounds.height)
        let visible = scrollView.documentVisibleRect
        let y = max(0, min(bounds.height,
                           visible.minY / documentHeight * bounds.height))
        let height = max(18, min(bounds.height,
                                 visible.height / documentHeight * bounds.height))
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: y,
                                         width: max(0, bounds.width - 2), height: height),
                     xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: 1.5, y: y + 0.5,
                                                       width: max(0, bounds.width - 3),
                                                       height: max(1, height - 1)),
                                   xRadius: 3, yRadius: 3)
        outline.lineWidth = 0.75
        outline.stroke()
    }

    private func color(for trimmed: String, isInsideCodeFence: Bool) -> NSColor {
        if trimmed.hasPrefix("#") { return .controlAccentColor.withAlphaComponent(0.78) }
        if isInsideCodeFence {
            return .systemOrange.withAlphaComponent(0.65)
        }
        if trimmed.hasPrefix(">") { return .systemPurple.withAlphaComponent(0.5) }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
            || trimmed.first?.isNumber == true {
            return .secondaryLabelColor.withAlphaComponent(0.62)
        }
        return .tertiaryLabelColor.withAlphaComponent(0.55)
    }

    private func lineIndex(in source: String, utf16Offset: Int) -> Int {
        let ns = source as NSString
        let end = max(0, min(utf16Offset, ns.length))
        guard end > 0 else { return 0 }
        return ns.substring(to: end).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }
}

import AppKit
import FloralMDCore

/// Lightweight semantic overview of a Markdown document. It deliberately
/// draws structure bars rather than tiny glyphs: headings, lists, quotes,
/// code-ish lines, Git changes, the caret line, and the visible viewport.
final class DocumentMinimapView: NSView {
    static let width: CGFloat = 78

    weak var editor: EditorTextView?

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
        let model = coordinateModel(for: editor)

        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        let strokeHeight = max(0.7, min(2, model.rowPitch * 0.55))
        let maxBarWidth = max(8, bounds.width - 12)
        let changes = editor.gitChangeSet
        let cursorY = model.rowOriginY(forUTF16Offset: editor.selectedRange().location)

        var rowUsesCodeColor = Array(repeating: false, count: lines.count)
        var isInsideCodeFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            rowUsesCodeColor[index] = isInsideCodeFence || isFence
            if isFence { isInsideCodeFence.toggle() }
        }

        let source = editor.rawSource as NSString
        for row in model.semanticRows {
            let line = lines[row.lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let leading = line.prefix { $0 == " " || $0 == "\t" }.count
            let x = min(maxBarWidth * 0.35, 5 + CGFloat(leading) * 1.45)
            if let change = changes.lines[row.lineIndex] {
                let color: NSColor = switch change {
                case .added: .systemGreen
                case .modified: .systemBlue
                }
                color.withAlphaComponent(0.9).setFill()
                NSRect(x: 2, y: row.y,
                       width: 2, height: max(1.5, strokeHeight)).fill()
            }
            guard !trimmed.isEmpty else { continue }
            let rowText = source.substring(with: row.sourceRange)
                .trimmingCharacters(in: .whitespaces)
            let visibleLength = max(3, rowText.utf16.count)
            let width = min(maxBarWidth - x + 4,
                            max(4, CGFloat(visibleLength) * 0.42))

            color(for: trimmed,
                  isInsideCodeFence: rowUsesCodeColor[row.lineIndex]).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: row.y, width: width,
                                             height: strokeHeight),
                         xRadius: strokeHeight / 2,
                         yRadius: strokeHeight / 2).fill()

            if abs(row.y - cursorY) < max(0.001, model.rowPitch * 0.5) {
                NSColor.controlAccentColor.setFill()
                NSRect(x: max(2, x - 3), y: row.y - 0.5,
                       width: min(bounds.width - x + 1, width + 5),
                       height: max(1.5, strokeHeight + 1)).fill()
            }
        }
        NSColor.systemRed.withAlphaComponent(0.9).setFill()
        for boundary in changes.deletionBoundaries {
            let y = model.y(forLineBoundary: boundary)
            NSRect(x: 2, y: y - 1, width: 5, height: 2).fill()
        }

        drawViewportIndicator(model: model)
    }

    override func mouseDown(with event: NSEvent) { scroll(to: event) }
    override func mouseDragged(with event: NSEvent) { scroll(to: event) }

    private func scroll(to event: NSEvent) {
        guard let editor else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let target = coordinateModel(for: editor).sourceOffset(atY: y)
        editor.scrollSourceOffsetToCenter(target)
        needsDisplay = true
    }

    private func drawViewportIndicator(model: DocumentMinimapCoordinateModel) {
        guard let editor,
              let sourceRange = editor.currentViewportSourceRange() else { return }
        let viewport = model.viewportRect(for: sourceRange)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: viewport.minY,
                                         width: max(0, bounds.width - 2),
                                         height: viewport.height),
                     xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: 1.5,
                                                       y: viewport.minY + 0.5,
                                                       width: max(0, bounds.width - 3),
                                                       height: max(1, viewport.height - 1)),
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

    private func coordinateModel(for editor: EditorTextView)
        -> DocumentMinimapCoordinateModel {
        let textWidth = max(1, editor.bounds.width - 2 * editor.textContainerInset.width)
        let fontSize = max(1, editor.font?.pointSize ?? NSFont.systemFontSize)
        let estimatedCharacterWidth = fontSize * 0.55
        let wrapColumn = max(16, Int(textWidth / estimatedCharacterWidth))
        return DocumentMinimapCoordinateModel(source: editor.rawSource,
                                              viewportHeight: bounds.height,
                                              wrapColumn: wrapColumn)
    }
}

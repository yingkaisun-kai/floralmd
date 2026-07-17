import AppKit

/// Low-contrast sidebar chrome. Stable cool-neutral surfaces carry hierarchy
/// without making every expand/collapse frame recompose a live blur.
enum QuietSidebarRole {
    case document
    case files
}

class QuietSidebarBackgroundView: NSView {
    private let role: QuietSidebarRole
    var backgroundOpacity: CGFloat = 1 {
        didSet {
            guard oldValue != backgroundOpacity else { return }
            needsDisplay = true
        }
    }

    init(role: QuietSidebarRole) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = backgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var backgroundColor: NSColor {
        let color = switch (role, isDarkAppearance) {
        case (.document, false): NSColor(srgbRed: 0.985, green: 0.987, blue: 0.992, alpha: 1)
        case (.files, false): NSColor(srgbRed: 0.965, green: 0.970, blue: 0.978, alpha: 1)
        case (.document, true): NSColor(srgbRed: 0.145, green: 0.148, blue: 0.155, alpha: 1)
        case (.files, true): NSColor(srgbRed: 0.165, green: 0.168, blue: 0.176, alpha: 1)
        }
        return color.withAlphaComponent(backgroundOpacity)
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

final class QuietSidebarSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class QuietSidebarRowView: NSTableRowView {
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        fillRoundedBackground(NSColor.labelColor.withAlphaComponent(0.035))
    }

    override func drawSelection(in dirtyRect: NSRect) {
        fillRoundedBackground(NSColor.labelColor.withAlphaComponent(0.075))
    }

    override func drawSeparator(in dirtyRect: NSRect) {}

    private func fillRoundedBackground(_ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2),
                     xRadius: 8, yRadius: 8).fill()
    }
}

final class QuietSidebarCellView: NSTableCellView {
    var imageLeadingConstraint: NSLayoutConstraint?
    var detailTextField: NSTextField?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

final class QuietSidebarLabel: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

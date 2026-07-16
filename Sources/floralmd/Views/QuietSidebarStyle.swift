import AppKit

/// Low-contrast, warm-neutral sidebar chrome inspired by native macOS utility
/// apps: structure is communicated by tone and hairlines rather than shadows.
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
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = switch (role, isDark) {
        case (.document, false): NSColor(srgbRed: 0.975, green: 0.972, blue: 0.963, alpha: 1)
        case (.files, false): NSColor(srgbRed: 0.955, green: 0.952, blue: 0.944, alpha: 1)
        case (.document, true): NSColor(srgbRed: 0.125, green: 0.125, blue: 0.120, alpha: 1)
        case (.files, true): NSColor(srgbRed: 0.105, green: 0.105, blue: 0.102, alpha: 1)
        }
        return color.withAlphaComponent(backgroundOpacity)
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
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1),
                     xRadius: 7, yRadius: 7).fill()
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

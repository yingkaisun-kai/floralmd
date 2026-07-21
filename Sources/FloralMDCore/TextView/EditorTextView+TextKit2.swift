// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit

// MARK: - TextKit 2 Support
//
// The editor runs on TextKit 2 (NSTextLayoutManager): layout is viewport-based
// — the system only lays out what's on screen, which is what makes large
// documents tractable. The hard rule that follows: never touch
// `NSTextView.layoutManager` or store NSTextBlock/NSTextTable attributes —
// either silently switches the view back to TextKit 1 for good.
//
// Custom attributes drive a custom layout fragment:
//
// - `.blockDecoration` (paragraph-level): callout boxes, quote bars, table
//   borders, thematic-break rules. Fragment frames tile vertically, so
//   per-paragraph drawing renders a multi-line quote run as one continuous
//   box/bar.
// - `.fragmentOverlay` (character-level): images drawn at a character's
//   position — callout header (icon + title), rendered math, list bullets and
//   checkboxes. TextKit 1 rendered `.attachment` over any character; TextKit 2
//   only honors attachments on U+FFFC, which the storage==rawSource invariant
//   forbids. Instead the anchor character is hidden, `.kern` reserves the
//   image's advance width (the same trick the table renderer uses for column
//   alignment), and the fragment draws the image at the anchor's position.
// - `.codeBlockLanguageLabel` (paragraph-level): a fenced code block's opening
//   row draws a small text label at the right edge without inserting display
//   characters into storage.
// - `.codeBlockPresentation` (paragraph-level): identifies every paragraph in
//   one fenced code block and carries its source-backed copy payload. Hover UI
//   reads this attribute from laid-out fragments; it never enters the text
//   storage as display content.

public extension NSAttributedString.Key {
    /// Paragraph-level decoration drawn behind the text by
    /// `DecoratedTextLayoutFragment`. Value: `BlockDecoration`.
    static let blockDecoration = NSAttributedString.Key("MarkdownEditor.blockDecoration")
    /// Character-level image drawn at the character's position by
    /// `DecoratedTextLayoutFragment`. Value: `FragmentOverlay`. The styling
    /// code pairs it with a hidden anchor glyph plus `.kern` for layout space.
    static let fragmentOverlay = NSAttributedString.Key("MarkdownEditor.fragmentOverlay")
    /// Paragraph-level `GitLineChangeKind` for a line changed from HEAD.
    static let gitChangeMarker = NSAttributedString.Key("MarkdownEditor.gitChangeMarker")
    /// Set of `GitDeletionEdge` values for deletions adjacent to this line.
    static let gitDeletionMarker = NSAttributedString.Key("MarkdownEditor.gitDeletionMarker")
    /// Paragraph-level presentation for an inactive table row. The raw
    /// Markdown remains in storage (and is revealed while editing); the custom
    /// fragment draws each cell in its own fixed-width wrapping rectangle.
    static let tableRowPresentation = NSAttributedString.Key("MarkdownEditor.tableRowPresentation")
    /// Display language on an inactive fenced code block's opening row.
    /// Value: a non-empty `String`; absent for unlabelled and plain-text fences.
    static let codeBlockLanguageLabel = NSAttributedString.Key(
        "MarkdownEditor.codeBlockLanguageLabel"
    )
    /// Presentation metadata shared by every paragraph in one fenced code
    /// block. The code payload excludes the opening/closing fences and info
    /// string. Value: `CodeBlockPresentation`.
    static let codeBlockPresentation = NSAttributedString.Key(
        "MarkdownEditor.codeBlockPresentation"
    )
}

/// Source-backed metadata for edit-mode fenced-code chrome. Reference identity
/// groups all laid-out paragraphs from one block during hover hit-testing.
public final class CodeBlockPresentation: NSObject, @unchecked Sendable {
    public let code: String
    public let isActive: Bool

    public init(code: String, isActive: Bool = false) {
        self.code = code
        self.isActive = isActive
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CodeBlockPresentation else { return false }
        return other.code == code && other.isActive == isActive
    }

    public override var hash: Int { code.hashValue ^ (isActive ? 1 : 0) }
}

/// Shared geometry keeps the language label and hover control disjoint even
/// for long labels or narrow text columns. Neither surface changes line height.
enum CodeBlockChromeLayout {
    // Match Read mode's block-level anchors instead of deriving chrome from a
    // text line's typographic bounds. User line spacing must not move either
    // control inside the code surface.
    static let cornerRadius: CGFloat = 8
    static let backgroundOutset: CGFloat = 8
    static let labelTopInset: CGFloat = 9
    static let labelLeadingInset: CGFloat = 12
    static let trailingInset: CGFloat = 8
    static let controlWidth: CGFloat = 76
    static let controlHeight: CGFloat = 28
    static let labelGap: CGFloat = 8

    /// A Lucide-like 14pt copy glyph centered in the 28pt button. Deriving
    /// from the button midpoint avoids the previous hard-coded 3pt up-left
    /// drift and keeps the icon balanced if the control size changes.
    static func copyIconRects(in buttonRect: CGRect) -> (back: CGRect, front: CGRect) {
        let glyphOrigin = CGPoint(x: buttonRect.midX - 7, y: buttonRect.midY - 7)
        let size = CGSize(width: 9, height: 9)
        return (
            CGRect(origin: glyphOrigin, size: size),
            CGRect(origin: CGPoint(x: glyphOrigin.x + 5, y: glyphOrigin.y + 5), size: size)
        )
    }

    static func languageLabelRect(blockLeft: CGFloat, blockWidth: CGFloat,
                                  textSize: CGSize) -> CGRect? {
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 4
        let maxX = blockLeft + blockWidth - trailingInset
            - controlWidth - labelGap
        let minX = blockLeft + labelLeadingInset
        let availableWidth = maxX - minX
        guard availableWidth >= 20 else { return nil }
        let width = min(ceil(textSize.width) + horizontalPadding * 2, availableWidth)
        let height = ceil(textSize.height) + verticalPadding * 2
        return CGRect(x: maxX - width,
                      y: labelTopInset,
                      width: width,
                      height: height)
    }
}

/// Visual cells for one inactive table row. Every row in a table receives the
/// same `columnWidths`, so independently wrapped cells still share one grid.
public final class TableRowPresentation: NSObject, @unchecked Sendable {
    public let cells: [NSAttributedString]
    public let columnWidths: [CGFloat]
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat

    public init(cells: [NSAttributedString], columnWidths: [CGFloat],
                horizontalPadding: CGFloat, verticalPadding: CGFloat) {
        self.cells = cells
        self.columnWidths = columnWidths
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableRowPresentation else { return false }
        return cells == other.cells && columnWidths == other.columnWidths
            && horizontalPadding == other.horizontalPadding
            && verticalPadding == other.verticalPadding
    }

    public override var hash: Int { cells.count ^ columnWidths.count }
}

/// Value object describing what to draw behind a decorated paragraph.
/// Reference type (NSObject) so it lives in attributed strings; value
/// equality so attribute-run merging and the test oracle behave.
public final class BlockDecoration: NSObject, @unchecked Sendable {

    public enum Kind: Equatable {
        /// Filled box across the text column (callouts), with optional borders.
        /// `bottomPad` extends the fill/border below the fragment's text frame —
        /// TextKit 2 does not include trailing `paragraphSpacing` in the
        /// fragment height, so a callout's last line carries the bottom padding
        /// here (and a matching paragraphSpacing pushes the next block clear).
        case box(background: NSColor, borderColor: NSColor?,
                 borderEdges: CalloutStyle.Edges, borderWidth: CGFloat,
                 bottomPad: CGFloat)
        /// Vertical bar just left of the paragraph's text (plain block quotes).
        case leftBar(color: NSColor, width: CGFloat)
        /// Table-row chrome for the open-table style. `width` is the table's
        /// full width and `leftInset` the text's inset from its left edge.
        /// `separator` draws the rule below the header; `bottomBorder` draws a
        /// rule between adjacent data rows. There is deliberately no outer
        /// frame and no vertical divider.
        case tableRow(width: CGFloat, leftInset: CGFloat, separator: Bool,
                      bottomBorder: Bool)
        /// Horizontal hairline across the text column, drawn `centerOffset`
        /// points below the fragment's vertical center. The offset compensates
        /// for adjacent text sitting at its baseline (low in its line box), so
        /// the rule looks equidistant from the text above and below rather
        /// than hugging the line above it.
        case horizontalRule(color: NSColor, centerOffset: CGFloat)
        /// Subtle dashed guides through ancestor list-marker columns.
        case indentGuides(xOffsets: [CGFloat], color: NSColor)
        /// A fenced code block's quiet full-column background and boundary.
        /// Paragraph fragments tile vertically; only the first/last paragraph
        /// draws the corresponding horizontal edge.
        case codeBlock(background: NSColor, borderColor: NSColor,
                       isFirst: Bool, isLast: Bool)
    }

    public let kind: Kind
    /// For `.box`: horizontal inset (points) from the text column's left and
    /// right edges, non-zero for a box nested inside another box (e.g. a
    /// callout inside a callout), so the inner box sits within the outer one.
    /// For `.leftBar`: rightward shift (points) from the outermost bar
    /// position — one `quoteMarkerWidth` per nesting level, mirroring the
    /// hidden `> ` marker that indents the text, so each nested quote's bar
    /// (e.g. `> > text`) sits just left of its own level's text. Absolute per
    /// level: the same level's bar lands at the same x on every line, which
    /// keeps stacked bars tiling into continuous columns. Ignored by other
    /// kinds.
    public let inset: CGFloat
    /// For `.leftBar`: start the bar at the first line's glyph top (baseline
    /// minus ascender) instead of the fragment top. The line box carries its
    /// extra spacing (lineSpacing) *above* the glyphs, so a bar over the full
    /// fragment pokes past the text. Set only on a quote run's first line —
    /// interior lines must fill the whole fragment so consecutive lines' bars
    /// tile without gaps. Ignored by other kinds.
    public let hugsTextTop: Bool

    public init(_ kind: Kind, inset: CGFloat = 0, hugsTextTop: Bool = false) {
        self.kind = kind
        self.inset = inset
        self.hugsTextTop = hugsTextTop
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockDecoration else { return false }
        return kind == other.kind && inset == other.inset
            && hugsTextTop == other.hugsTextTop
    }

    public override var hash: Int {
        switch kind {
        case .box: return 1
        case .leftBar: return 2
        case .tableRow: return 3
        case .horizontalRule: return 4
        case .indentGuides: return 5
        case .codeBlock: return 6
        }
    }
}

/// An ordered stack of decorations drawn behind one paragraph, outermost
/// first. Used when nesting puts more than one box/bar on the same line — e.g.
/// a callout's outer box plus an inner nested callout's box. A single
/// decoration still uses a bare `BlockDecoration`; the fragment reads either.
public final class BlockDecorationList: NSObject, @unchecked Sendable {
    public let decorations: [BlockDecoration]

    public init(_ decorations: [BlockDecoration]) {
        self.decorations = decorations
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockDecorationList else { return false }
        return decorations == other.decorations
    }

    public override var hash: Int { decorations.count }
}

/// An image or stroked vector path drawn at a character's laid-out position,
/// with attachment-style bounds: `bounds.origin.y` is the drawing's bottom
/// relative to the text baseline (negative descends below it).
///
/// The path form exists because of a TextKit 2 wedge: drawing an *image* on a
/// wrapping, multi-line layout fragment collapses that fragment's layout to a
/// single line, while drawing a *shape* does not. Overlays that can share a line
/// with wrapping text (the custom-callout-title icon) must use the path form.
public final class FragmentOverlay: NSObject, @unchecked Sendable {
    public enum Role: Sendable {
        case presentation
        case resizableImage
    }

    public let image: NSImage?
    /// Stroked path in bounds-local coordinates (y-down, origin at the
    /// bounds' top-left), pre-scaled to the bounds size.
    public let path: CGPath?
    public let pathColor: NSColor?
    public let pathLineWidth: CGFloat
    public let bounds: CGRect
    public let role: Role

    /// A resize drag promotes this bitmap into the editor's foreground preview
    /// view. Suppress the fragment copy so shrinking cannot reveal the stored-
    /// size image underneath while TextKit coalesces display updates.
    nonisolated(unsafe) var suppressesImageDrawing = false

    public init(image: NSImage, bounds: CGRect, role: Role = .presentation) {
        self.image = image
        self.path = nil
        self.pathColor = nil
        self.pathLineWidth = 0
        self.bounds = bounds
        self.role = role
        super.init()
    }

    public init(path: CGPath, color: NSColor, lineWidth: CGFloat, bounds: CGRect) {
        self.image = nil
        self.path = path
        self.pathColor = color
        self.pathLineWidth = lineWidth
        self.bounds = bounds
        self.role = .presentation
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FragmentOverlay else { return false }
        return other.image === image && other.path == path
            && other.pathColor == pathColor && other.pathLineWidth == pathLineWidth
            && other.bounds == bounds && other.role == role
    }

    public override var hash: Int { Int(bounds.width) ^ Int(bounds.height) }
}

/// Layout fragment that draws its paragraph's `BlockDecoration` behind the
/// text and any `FragmentOverlay` images at their characters' positions.
final class DecoratedTextLayoutFragment: NSTextLayoutFragment {

    /// Decorations drawn behind the paragraph, outermost first.
    let decorations: [BlockDecoration]
    /// Paragraph-relative anchor offsets and their overlays.
    let overlays: [(offset: Int, overlay: FragmentOverlay)]
    /// Whether the text is antialiased (editor-wide setting).
    let antialias: Bool
    let gitChange: GitLineChangeKind?
    let gitDeletionEdges: Set<GitDeletionEdge>
    let tableRowPresentation: TableRowPresentation?
    /// Optional language label drawn inside this opening fence row.
    let codeBlockLanguageLabel: String?
    /// Shared metadata for edit-mode hover hit-testing and raw-code copying.
    let codeBlockPresentation: CodeBlockPresentation?

    init(textElement: NSTextElement, range: NSTextRange?,
         decorations: [BlockDecoration],
         overlays: [(offset: Int, overlay: FragmentOverlay)],
         tableRowPresentation: TableRowPresentation?,
         gitChange: GitLineChangeKind?,
         gitDeletionEdges: Set<GitDeletionEdge>,
         codeBlockLanguageLabel: String?,
         codeBlockPresentation: CodeBlockPresentation?,
         antialias: Bool) {
        self.decorations = decorations
        self.overlays = overlays
        self.tableRowPresentation = tableRowPresentation
        self.gitChange = gitChange
        self.gitDeletionEdges = gitDeletionEdges
        self.codeBlockLanguageLabel = codeBlockLanguageLabel
        self.codeBlockPresentation = codeBlockPresentation
        self.antialias = antialias
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("DecoratedTextLayoutFragment does not support coding")
    }

    /// Fragment-local x of the text container's left edge. The fragment's
    /// frame hugs the laid-out text, so container x = 0 sits at -frame.minX.
    private var containerLeft: CGFloat { -layoutFragmentFrame.minX }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// Keep the deletion triangle inside its owning fragment. TextKit 2 may
    /// paint the adjacent fragment after this one, covering any half that
    /// straddles the inter-line boundary even when renderingSurfaceBounds
    /// includes the overhang.
    static func gitDeletionTriangleBounds(edge: GitDeletionEdge,
                                          fragmentHeight: CGFloat) -> CGRect {
        let centerInset = min(5, fragmentHeight / 2)
        let centerY = edge == .before ? centerInset : fragmentHeight - centerInset
        return CGRect(x: 0, y: centerY - 4, width: 6, height: 8)
    }

    /// A box decoration's `bottomPad` grows the fragment's own frame (not just
    /// its drawing): TextKit 2 leaves trailing `paragraphSpacing` out of the
    /// fragment, so padding added that way is dead space — clicks there miss the
    /// text. Making the fragment frame taller means the line fragments stay
    /// anchored at the top, the extra height is genuine clickable space below
    /// the last line, the next block tiles clear of it, and the box (drawn over
    /// the full frame height) covers it. Mirrors how the header's raised
    /// minimumLineHeight makes the top padding clickable text space.
    ///
    /// Padding is *summed* across stacked boxes: when a nested callout is the
    /// last line of its parent, the line needs the nested box's bottom padding
    /// *and* the parent's below it (see `draw`), so both fit.
    private var boxBottomPad: CGFloat {
        decorations.reduce(0) { acc, deco in
            if case .box(_, _, _, _, let bottomPad) = deco.kind { return acc + bottomPad }
            return acc
        }
    }

    private var absorbsTrailingEmptyLine: Bool {
        textLineFragments.count > 1
            && textLineFragments.last?.characterRange.length == 0
    }

    /// Height to actually paint a filled decoration (box / left bar) over,
    /// which is *not* always the full frame height. When a callout or quote is
    /// the last block AND the document ends with a newline, TextKit 2 folds the
    /// document's final empty line into this (the preceding) layout fragment
    /// instead of giving it its own fragment — it shows up as a trailing
    /// zero-length line fragment. Painting the decoration over the full frame
    /// then floods the callout color onto that trailing empty line (the
    /// "extra colored line at the bottom" bug). Detect the absorbed empty line
    /// and stop the fill at the last real content line plus the box's bottom
    /// padding.
    var decorationDrawHeight: CGFloat {
        let full = layoutFragmentFrame.height
        let lines = textLineFragments
        guard absorbsTrailingEmptyLine else { return full }
        // Bottom of the last line that actually holds text (fragment-local).
        let contentBottom = lines.dropLast().map { $0.typographicBounds.maxY }.max() ?? 0
        // `super` frame excludes our bottomPad; its extent past the content is
        // exactly the absorbed empty line. Remove that, keep the bottomPad.
        let emptyLineHeight = max(0, super.layoutFragmentFrame.height - contentBottom)
        return max(0, full - emptyLineHeight)
    }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height += boxBottomPad
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        let frame = layoutFragmentFrame
        if !decorations.isEmpty {
            bounds = bounds.union(CGRect(x: containerLeft - 10, y: 0,
                                         width: containerWidth + 20, height: frame.height))
        }
        if gitChange != nil || !gitDeletionEdges.isEmpty {
            bounds = bounds.union(CGRect(x: containerLeft - 12, y: 0,
                                         width: 6, height: layoutFragmentFrame.height))
        }
        for (offset, overlay) in overlays {
            if let rect = overlayRect(anchorOffset: offset, overlay: overlay) {
                bounds = bounds.union(rect.insetBy(dx: -2, dy: -2))
            }
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let gitChange {
            let frame = layoutFragmentFrame
            let x = point.x + containerLeft - 9
            let color: NSColor = switch gitChange {
            case .added: .systemGreen
            case .modified: .systemBlue
            }
            context.setFillColor(color.withAlphaComponent(0.85).cgColor)
            context.fill(CGRect(x: x, y: point.y + 1,
                                width: 3, height: max(3, frame.height - 2)))
        }
        if !gitDeletionEdges.isEmpty {
            let frame = layoutFragmentFrame
            let x = point.x + containerLeft - 10
            context.setFillColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
            for edge in gitDeletionEdges {
                let triangle = Self.gitDeletionTriangleBounds(
                    edge: edge, fragmentHeight: frame.height
                )
                let y = point.y + triangle.midY
                context.beginPath()
                context.move(to: CGPoint(x: x, y: y - 4))
                context.addLine(to: CGPoint(x: x + triangle.width, y: y))
                context.addLine(to: CGPoint(x: x, y: y + 4))
                context.closePath()
                context.fillPath()
            }
        }
        context.saveGState()
        // Decorations are stacked outermost-first. Each box stops short of the
        // fragment bottom by the padding of the boxes drawn before it, so an
        // outer box's bottom padding stays visible *below* an inner nested box
        // (e.g. the parent callout's padding under a nested callout) instead of
        // being covered by it.
        var precedingBottomPad: CGFloat = 0
        for decoration in decorations {
            drawDecoration(decoration, at: point, in: context, bottomInset: precedingBottomPad)
            if case .box(_, _, _, _, let bottomPad) = decoration.kind {
                precedingBottomPad += bottomPad
            }
        }
        context.restoreGState()
        if let tableRowPresentation {
            drawTableRow(tableRowPresentation, at: point, in: context)
        }
        context.saveGState()
        context.setShouldAntialias(antialias)
        super.draw(at: point, in: context)
        context.restoreGState()
        for (offset, overlay) in overlays {
            guard let rect = overlayRect(anchorOffset: offset, overlay: overlay) else { continue }
            let drawRect = rect.offsetBy(dx: point.x, dy: point.y)
            if let image = overlay.image, !overlay.suppressesImageDrawing {
                // Draw the (resolution-independent) NSImage into the flipped context,
                // so it rasterizes at the screen's backing scale — crisp on Retina,
                // and positioned precisely. (Converting to a CGImage first would bake
                // it at 1×, then upscale: soft, and quantized a pixel low.) The math
                // image carries a small transparent inset, so the flipped draw can't
                // clip a descender at the image edge.
                let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = nsContext
                image.draw(in: drawRect, from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else if let path = overlay.path, let color = overlay.pathColor {
                // Stroke the vector path directly in CG — never rasterize it to
                // an image first: an image drawn on a multi-line fragment wedges
                // its layout to one line (see the FragmentOverlay note). Path
                // coords are bounds-local and y-down, matching this flipped
                // context, so a translate places them.
                context.saveGState()
                context.translateBy(x: drawRect.minX, y: drawRect.minY)
                context.addPath(path)
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(overlay.pathLineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
                context.restoreGState()
            }
        }
    }

    private func drawTableRow(_ row: TableRowPresentation, at point: CGPoint,
                              in context: CGContext) {
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        // A trailing document newline is folded into the final table row's
        // fragment. That fragment loses the normal first-line indent in its
        // drawing origin, so compensate only that absorbed-empty-line case;
        // ordinary rows keep their established position.
        var x = point.x + (absorbsTrailingEmptyLine ? row.horizontalPadding : 0)
        for index in 0..<min(row.cells.count, row.columnWidths.count) {
            let width = row.columnWidths[index]
            let rect = CGRect(
                x: x,
                y: point.y + row.verticalPadding,
                width: max(1, width - 2 * row.horizontalPadding),
                height: max(1, layoutFragmentFrame.height - 2 * row.verticalPadding)
            )
            row.cells[index].draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Fragment-local rect for an overlay image, anchored to the character at
    /// the given paragraph-relative offset.
    func overlayRect(anchorOffset: Int, overlay: FragmentOverlay) -> CGRect? {
        guard let line = textLineFragments.first(where: {
            NSLocationInRange(anchorOffset, $0.characterRange)
        }) ?? textLineFragments.last else { return nil }
        let anchorX = line.typographicBounds.minX
            + line.locationForCharacter(at: anchorOffset).x
        // Baseline (flipped coords): the line's glyph origin sits at its
        // typographic origin plus the ascent-derived glyph origin.
        let baselineY = line.typographicBounds.minY + line.glyphOrigin.y
        let bounds = overlay.bounds
        return CGRect(x: anchorX + bounds.minX,
                      y: baselineY - bounds.height - bounds.minY,
                      width: bounds.width,
                      height: bounds.height)
    }

    /// Fragment-local y of the first line's glyph top (baseline minus the
    /// line's font ascender). The line box can hold extra space above the
    /// glyphs (lineSpacing lands there), which a text-hugging bar skips.
    private var firstLineGlyphTop: CGFloat? {
        guard let line = textLineFragments.first,
              line.characterRange.length > 0,
              let font = line.attributedString.attribute(
                  .font, at: line.characterRange.location, effectiveRange: nil) as? NSFont
        else { return nil }
        return line.typographicBounds.minY + line.glyphOrigin.y - font.ascender
    }

    private func drawDecoration(_ decoration: BlockDecoration, at point: CGPoint,
                                in context: CGContext, bottomInset: CGFloat = 0) {
        let frame = layoutFragmentFrame
        // Filled decorations (box, bar) stop above an absorbed trailing empty
        // line; center-line decorations (rule, table) still use the full frame.
        let fillHeight = decorationDrawHeight
        // Fragment-local rect spanning the full text column for this fragment.
        let columnRect = CGRect(x: point.x + containerLeft, y: point.y,
                                width: containerWidth, height: fillHeight)

        switch decoration.kind {
        case .box(let background, let borderColor, let edges, let borderWidth, _):
            // The fragment frame already includes any box bottomPad (see
            // layoutFragmentFrame), so columnRect covers the padded area. A
            // nested box insets symmetrically so it sits within its parent box,
            // and stops `bottomInset` short of the frame bottom so the enclosing
            // box's padding shows below it.
            var columnRect = decoration.inset > 0
                ? columnRect.insetBy(dx: decoration.inset, dy: 0)
                : columnRect
            columnRect.size.height -= bottomInset
            context.setFillColor(background.cgColor)
            context.fill(columnRect)
            if let borderColor, !edges.isEmpty {
                context.setFillColor(borderColor.cgColor)
                if edges.contains(.left) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.minY,
                                        width: borderWidth, height: columnRect.height))
                }
                if edges.contains(.right) {
                    context.fill(CGRect(x: columnRect.maxX - borderWidth, y: columnRect.minY,
                                        width: borderWidth, height: columnRect.height))
                }
                if edges.contains(.top) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.minY,
                                        width: columnRect.width, height: borderWidth))
                }
                if edges.contains(.bottom) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.maxY - borderWidth,
                                        width: columnRect.width, height: borderWidth))
                }
            }

        case .leftBar(let color, let width):
            // The bar sits immediately left of the text (the paragraph style
            // insets the text by the bar's width) — or `inset` further right,
            // for a nested quote's bar next to its own level's text.
            var barTop = point.y
            var barHeight = fillHeight
            if decoration.hugsTextTop, let glyphTop = firstLineGlyphTop {
                barTop += glyphTop
                barHeight -= glyphTop
            }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: point.x - width + decoration.inset, y: barTop,
                                width: width, height: barHeight))

        case .tableRow(let width, let leftInset, let separator, let bottomBorder):
            let textX = point.x + (absorbsTrailingEmptyLine ? leftInset : 0)
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(1)
            if separator {
                let y = round(point.y + frame.height / 2) + 0.5
                context.move(to: CGPoint(x: textX - leftInset, y: y))
                context.addLine(to: CGPoint(x: textX - leftInset + width, y: y))
            }
            if bottomBorder {
                let y = round(point.y + frame.height) + 0.5
                context.move(to: CGPoint(x: textX - leftInset, y: y))
                context.addLine(to: CGPoint(x: textX - leftInset + width, y: y))
            }
            context.strokePath()

        case .horizontalRule(let color, let centerOffset):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            let y = round(point.y + frame.height / 2 + centerOffset) + 0.5
            context.move(to: CGPoint(x: columnRect.minX, y: y))
            context.addLine(to: CGPoint(x: columnRect.maxX, y: y))
            context.strokePath()

        case .indentGuides(let xOffsets, let color):
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [2, 3])
            for offset in xOffsets {
                let x = round(columnRect.minX + offset) + 0.5
                context.move(to: CGPoint(x: x, y: point.y))
                context.addLine(to: CGPoint(x: x, y: point.y + frame.height))
            }
            context.strokePath()
            context.restoreGState()

        case .codeBlock(let background, let borderColor, let isFirst, let isLast):
            // Extend into the editor's existing text-container margin instead
            // of indenting code. This creates visual padding without changing
            // wrapping, line height, source offsets, or caret geometry.
            let rect = columnRect.insetBy(dx: -CodeBlockChromeLayout.backgroundOutset, dy: 0)
            let radius = min(CodeBlockChromeLayout.cornerRadius,
                             rect.width / 2, rect.height / 2)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX,
                                  y: rect.minY + (isFirst ? radius : 0)))
            if isFirst {
                path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                                  control: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
                path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                                  control: CGPoint(x: rect.maxX, y: rect.minY))
            } else {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            path.addLine(to: CGPoint(x: rect.maxX,
                                     y: rect.maxY - (isLast ? radius : 0)))
            if isLast {
                path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                                  control: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
                path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                                  control: CGPoint(x: rect.minX, y: rect.maxY))
            } else {
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            path.closeSubpath()
            context.setFillColor(background.cgColor)
            context.addPath(path)
            context.fillPath()

            context.setStrokeColor(borderColor.cgColor)
            let hairline = 1 / max(1, abs(context.ctm.a))
            context.setLineWidth(hairline)
            let borderPath = CGMutablePath()
            borderPath.move(to: CGPoint(x: rect.minX,
                                        y: rect.minY + (isFirst ? radius : 0)))
            borderPath.addLine(to: CGPoint(x: rect.minX,
                                           y: rect.maxY - (isLast ? radius : 0)))
            borderPath.move(to: CGPoint(x: rect.maxX,
                                        y: rect.minY + (isFirst ? radius : 0)))
            borderPath.addLine(to: CGPoint(x: rect.maxX,
                                           y: rect.maxY - (isLast ? radius : 0)))
            if isFirst {
                borderPath.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
                borderPath.addQuadCurve(
                    to: CGPoint(x: rect.minX + radius, y: rect.minY),
                    control: CGPoint(x: rect.minX, y: rect.minY)
                )
                borderPath.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
                borderPath.addQuadCurve(
                    to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                    control: CGPoint(x: rect.maxX, y: rect.minY)
                )
            }
            if isLast {
                borderPath.move(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
                borderPath.addQuadCurve(
                    to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                    control: CGPoint(x: rect.minX, y: rect.maxY)
                )
                borderPath.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
                borderPath.addQuadCurve(
                    to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                    control: CGPoint(x: rect.maxX, y: rect.maxY)
                )
            }
            context.addPath(borderPath)
            context.strokePath()
        }
    }
}

// MARK: - Fragment Vending

extension EditorTextView: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0 else {
            return NSTextLayoutFragment(textElement: textElement,
                                        range: textElement.elementRange)
        }
        let str = paragraph.attributedString
        let gitChange = str.attribute(.gitChangeMarker, at: 0,
                                      effectiveRange: nil) as? GitLineChangeKind
        let gitDeletionEdges = str.attribute(.gitDeletionMarker, at: 0,
                                             effectiveRange: nil) as? Set<GitDeletionEdge> ?? []
        let tableRowPresentation = str.attribute(
            .tableRowPresentation, at: 0, effectiveRange: nil
        ) as? TableRowPresentation
        let codeBlockLanguageLabel = str.attribute(
            .codeBlockLanguageLabel, at: 0, effectiveRange: nil
        ) as? String
        let codeBlockPresentation = str.attribute(
            .codeBlockPresentation, at: 0, effectiveRange: nil
        ) as? CodeBlockPresentation
        let decoValue = str.attribute(.blockDecoration, at: 0, effectiveRange: nil)
        let decorations: [BlockDecoration]
        if let list = decoValue as? BlockDecorationList {
            decorations = list.decorations
        } else if let single = decoValue as? BlockDecoration {
            decorations = [single]
        } else {
            decorations = []
        }
        var overlays: [(offset: Int, overlay: FragmentOverlay)] = []
        str.enumerateAttribute(.fragmentOverlay,
                               in: NSRange(location: 0, length: str.length),
                               options: []) { value, range, _ in
            if let overlay = value as? FragmentOverlay {
                overlays.append((range.location, overlay))
            }
        }
        // A plain fragment suffices only when there's nothing to draw over the
        // text and antialiasing is on (the default); otherwise vend the custom
        // fragment so its draw can disable antialiasing.
        guard !decorations.isEmpty || !overlays.isEmpty || tableRowPresentation != nil
                || codeBlockLanguageLabel != nil
                || codeBlockPresentation != nil
                || gitChange != nil || !gitDeletionEdges.isEmpty || !textAntialias else {
            return NSTextLayoutFragment(textElement: textElement,
                                        range: textElement.elementRange)
        }
        return DecoratedTextLayoutFragment(textElement: textElement,
                                           range: textElement.elementRange,
                                           decorations: decorations,
                                           overlays: overlays,
                                           tableRowPresentation: tableRowPresentation,
                                           gitChange: gitChange,
                                           gitDeletionEdges: gitDeletionEdges,
                                           codeBlockLanguageLabel: codeBlockLanguageLabel,
                                           codeBlockPresentation: codeBlockPresentation,
                                           antialias: textAntialias)
    }
}

// MARK: - Overlay Application

extension EditorTextView {
    /// Renders `overlay` at `anchor` (a single character): hides the anchor
    /// glyph, reserves the image's advance width with kern so following text
    /// flows around it, and stores the overlay for the layout fragment to draw.
    ///
    /// The kern is capped just short of the full line width: a full-width
    /// image/equation (the common case — anything wider than the column gets
    /// scaled to exactly fill it) would otherwise reserve 100% of the line,
    /// leaving zero room for the hidden markdown text that follows the anchor
    /// on the same line. TextKit then force-wraps that hidden run onto a new
    /// line fragment — and since `minimumLineHeight` (reserveLineHeight) is a
    /// paragraph-wide property applying to every line fragment, that phantom
    /// wrapped line also inflates to the overlay's full height, doubling the
    /// reserved space below the image. The slack is comfortably larger than
    /// any realistic hidden-text width (near-zero at `hiddenFont`'s size).
    func applyOverlay(_ overlay: FragmentOverlay, anchor: NSRange,
                      in result: NSMutableAttributedString) {
        guard anchor.upperBound <= result.length else { return }
        let kernSlack: CGFloat = 8
        let kernWidth = min(overlay.bounds.width, max(0, availableContentWidth - kernSlack))
        result.addAttribute(.font, value: hiddenFont, range: anchor)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: anchor)
        result.addAttribute(.kern, value: kernWidth, range: anchor)
        result.addAttribute(.fragmentOverlay, value: overlay, range: anchor)
    }

    /// Reserves vertical room for an overlay taller than the text line that
    /// carries it. A `FragmentOverlay` only reserves horizontal advance (kern),
    /// so — unlike the old `NSTextAttachment`, which grew its line fragment —
    /// a tall image or equation would otherwise overlap adjacent lines. Reserve
    /// the part above the baseline as line height and the descent as trailing
    /// paragraph space; putting the full image in `minimumLineHeight` pins the
    /// baseline too low and lets the descent hang into the next paragraph.
    func reserveLineHeight(ascent: CGFloat, descent: CGFloat, forOverlayAt location: Int,
                           in result: NSMutableAttributedString) {
        guard location < result.length else { return }
        let ns = result.string as NSString
        // The enclosing paragraph (between newlines): minimumLineHeight is a
        // paragraph attribute, and for the heading/inline cases the math sits
        // on a single line, so this grows exactly the line that needs it.
        let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
        let base = (result.attribute(.paragraphStyle, at: location, effectiveRange: nil)
            as? NSParagraphStyle) ?? bodyParagraphStyle
        guard ascent > base.minimumLineHeight || descent > base.paragraphSpacing else { return }
        let ps = (base.mutableCopy() as! NSMutableParagraphStyle)
        ps.minimumLineHeight = max(base.minimumLineHeight, ascent)
        ps.paragraphSpacing = max(base.paragraphSpacing, descent)
        result.addAttribute(.paragraphStyle, value: ps, range: para)
    }
}

// MARK: - Stack Construction

public extension EditorTextView {
    /// Builds the TextKit 2 text system chain and returns the wired editor:
    ///   EditorTextStorage → NSTextContentStorage → NSTextLayoutManager
    ///   → NSTextContainer → EditorTextView
    static func makeTextKit2(frame: NSRect, containerSize: NSSize) -> EditorTextView {
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = EditorTextStorage()

        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(size: containerSize)
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        return EditorTextView(frame: frame, textContainer: container)
    }
}

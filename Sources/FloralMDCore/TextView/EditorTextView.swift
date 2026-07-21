// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit

public extension Notification.Name {
    /// Posted after storage, rawSource, parsed blocks, and presentation
    /// attributes have all caught up with an editor change.
    static let editorDidSynchronizeText = Notification.Name(
        "FloralMD.EditorDidSynchronizeText"
    )
}

/// Delayed, event-transparent link gesture hint. TextKit 2 does not reliably
/// surface `NSToolTipAttributeName` from the attributed storage, so the editor
/// owns this tiny AppKit presentation instead of claiming a tooltip exists when
/// only the attribute is present. It never accepts mouse events or first responder.
final class LinkHoverHintView: NSVisualEffectView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .toolTip
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, near linkRect: NSRect, in visibleRect: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 16, height: label.frame.height + 10)
        var x = linkRect.minX
        var y = linkRect.minY - size.height - 6
        if y < visibleRect.minY + 4 { y = linkRect.maxY + 6 }
        x = min(max(x, visibleRect.minX + 4), max(visibleRect.minX + 4, visibleRect.maxX - size.width - 4))
        y = min(max(y, visibleRect.minY + 4), max(visibleRect.minY + 4, visibleRect.maxY - size.height - 4))
        frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        label.frame.origin = NSPoint(x: 8, y: 5)
        isHidden = false
    }
}

/// A single NSTextView with word-level inline preview.
///
/// ## Architecture
///
/// `rawSource` is the **sole source of truth** for document content.
/// The text storage always contains rawSource — no delimiter stripping.
/// All formatting is achieved through NSAttributedString attributes:
///   - Inline delimiters (`**`, `*`, `` ` ``, etc.) are hidden via near-zero
///     font size when the cursor is not inside the token.
///   - Block-level markers (`#`, `>`, `-`, etc.) are always visible and dimmed.
///   - Content gets rich text styling (bold, italic, colors, etc.).
///
/// **Edits** flow through NSTextView's normal path:
///   1. `shouldChangeText` records an undo snapshot (coalesced), returns `true`
///   2. NSTextView applies the edit to the text storage
///   3. `didChangeText` fires — we sync `rawSource` and re-style the block
///
/// **Cursor movement** is detected via `didChangeSelectionNotification`.
/// When the cursor moves to a different block, we restyle both blocks.
/// When it moves within a block, we update which token's delimiters
/// are visible (the "active token").
///
/// **Undo/Redo** uses custom stacks of `rawSource` snapshots, completely
/// bypassing NSTextView's built-in undo.
public class EditorTextView: NSTextView {

    // MARK: - Document Link

    /// Weak reference to the owning NSDocument, used for dirty-state tracking.
    /// Set by Document.makeWindowControllers(). Not available in unit tests.
    public weak var document: NSDocument?

    /// The app target owns clipboard image persistence and naming UI. Core only
    /// gives it first refusal; every non-image paste continues through AppKit's
    /// ordinary text path unchanged.
    public var imagePasteHandler: (() -> Bool)?

    /// Localized edit-mode code-copy labels. The app layer supplies the same
    /// strings used by Read mode; Core defaults to English for tests/embedding.
    public var codeBlockCopyStrings: ReadModeCopyStrings = .english {
        didSet { codeBlockControlView.updateStrings(codeBlockCopyStrings) }
    }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for imageType in [NSPasteboard.PasteboardType.png, .tiff] where !types.contains(imageType) {
            types.append(imageType)
        }
        return types
    }

    public override func paste(_ sender: Any?) {
        if imagePasteHandler?() == true { return }
        // Never let NSTextView turn an unhandled bitmap into an attachment;
        // storage must remain raw Markdown even if the app handler is absent.
        let types = NSPasteboard.general.types ?? []
        if types.contains(.png) || types.contains(.tiff) {
            NSSound.beep()
            return
        }
        super.paste(sender)
    }

    // MARK: - State (internal for @testable import)

    public var rawSource: String = ""
    /// Current-line changes and deleted inter-line boundaries from HEAD.
    public var gitChangeSet = GitLineChangeSet() {
        didSet { applyGitChangeMarkers() }
    }
    /// Columns of leading whitespace that make up one list-nesting level,
    /// detected from the document (the smallest indent used, or one tab).
    /// Defaults to 4. Used to map a list item's indentation to a nesting depth.
    /// Maintained incrementally from `listIndentState` on the edit path;
    /// rebuilt by the whole-document paths (load, undo, indent).
    public var listIndentUnit: Int = 4
    /// Histogram of indented-list-line indents (see ListIndentState) backing
    /// the incremental `listIndentUnit`.
    var listIndentState = ListIndentState()

    /// Rebuilds the indent histogram from the whole document. O(n) — for the
    /// paths that rebuilt rawSource anyway; the edit path updates per block.
    func rebuildListIndentState() {
        listIndentState = ListIndentState.build(from: rawSource)
        listIndentUnit = listIndentState.unit
    }

    /// Document-wide link reference definitions (`[label]: url`), fed into each
    /// block's parse so GFM reference links resolve across blocks. Maintained
    /// incrementally on the edit path; rebuilt by the whole-document paths.
    var linkDefState = LinkDefinitionState()

    func rebuildLinkDefState() {
        linkDefState = LinkDefinitionState.build(from: rawSource)
    }
    /// Line ending of the most recently loaded content. The buffer itself is
    /// always LF; this is remembered so saves preserve the file's style.
    public var originalLineEnding: LineEnding = .lf
    var blocks: [Block] = []
    var activeBlockIndex: Int? = nil
    var isUpdating = false
    /// Coalesces the async active-block restyle scheduled from a caret move
    /// (internal so EditorTextView+SelectionTracking can clear it).
    var pendingRecompose = false
    /// Coalesces idle-drain scheduling (see EditorTextView+LazyStyling).
    var progressiveStylingScheduled = false
    /// Coalesces scroll-driven promotion onto the next run-loop turn, off the
    /// scroll notification (see EditorTextView+LazyStyling).
    var pendingPromotion = false
    /// Coalesces the didChangeText-bypass check scheduled from
    /// shouldChangeText (see EditorTextView+EditFlow).
    var bypassedEditCheckScheduled = false
    /// Where the idle drain resumes scanning for unstyled blocks (a hint;
    /// it wraps around and self-corrects after edits shift indices).
    var drainCursor = 0
    /// Coalesces the deferred full-document layout settle for small documents
    /// (see EditorTextView+LazyStyling `scheduleFullLayoutSettle`).
    var fullLayoutSettleScheduled = false
    /// TextKit 2's system caret includes line spacing and bypasses the public
    /// draw hook. This explicit foreground indicator is positioned and blinked
    /// by EditorTextView+InsertionPoint while the system caret stays clear.
    let fontHeightInsertionIndicator = NSTextInsertionIndicator(frame: .zero)
    var insertionIndicatorUpdateScheduled = false
    var insertionIndicatorBlinkTimer: Timer?
    var pointerTrackingArea: NSTrackingArea?
    var hoveredImageOverlay: ImageOverlayHit?
    var imageResizeSession: ImageResizeSession?
    let imageResizeChromeView = ImageResizeChromeView(frame: .zero)
    var hoveredCodeBlock: CodeBlockHit?
    let codeBlockLanguageOverlayView = CodeBlockLanguageOverlayView(frame: .zero)
    let codeBlockControlView = CodeBlockControlView(frame: .zero)
    var codeBlockCopyPasteboard: NSPasteboard = .general
    struct HoveredLinkHit: Equatable {
        let range: NSRange
        let cursorRect: NSRect
    }
    var hoveredLinkHit: HoveredLinkHit?
    var linkHintShowWorkItem: DispatchWorkItem?
    let linkHoverHintView = LinkHoverHintView(frame: .zero)
    var pointerModifierFlags: NSEvent.ModifierFlags = []
    /// App-layer copy for the hover hint and accessibility help.
    /// The executable target owns interface-language selection; Core owns the
    /// hover lifecycle and defaults to English for standalone/test use.
    public var linkNavigationHint = "Hold Command and click to follow link" {
        didSet {
            guard linkNavigationHint != oldValue else { return }
            linkHoverHintView.label.stringValue = linkNavigationHint
            if hoveredLinkHit != nil { setAccessibilityHelp(linkNavigationHint) }
            if let hit = hoveredLinkHit, !linkHoverHintView.isHidden {
                linkHoverHintView.show(linkNavigationHint, near: hit.cursorRect, in: visibleRect)
            }
        }
    }
    /// Documents at or below this UTF-16 length are laid out in full once
    /// styling converges, eliminating TextKit 2 height estimates (and the
    /// scroll jumps they cause). See `scheduleFullLayoutSettle`.
    static let fullLayoutMaxLength = 100_000

    // MARK: - Custom Undo/Redo State

    struct UndoSnapshot {
        let rawSource: String
        let cursorInRaw: Int
    }

    enum EditType { case insert, delete, other }

    var undoStack: [UndoSnapshot] = []
    var redoStack: [UndoSnapshot] = []
    var lastEditBlockIndex: Int? = nil
    var lastEditType: EditType = .other
    var isUndoRedoing = false
    /// The first storage mutation in a custom undo group owns the matching
    /// NSDocument `.changeDone`. Later characters in the same typing run must
    /// not increment the document count again or one Undo could never return
    /// the document to its saved baseline.
    var pendingDocumentChangeGroupStart = false

    /// The separator between blocks in the display.
    /// Must match what BlockParser splits on.
    let blockSeparator = "\n"

    // MARK: - Theme (user-configurable visual settings)

    /// The UserDefaults domain backing theme persistence. Defaults to the
    /// shared `.standard` store; tests override it to isolate from the real
    /// domain (and from each other under parallel execution).
    public var themeDefaults: UserDefaults = .standard

    public var theme: EditorTheme = .load() {
        didSet { textAntialias = theme.antialias }
    }

    /// Mirror of `theme.antialias`, readable from the `nonisolated`
    /// layout-fragment vendor.
    nonisolated(unsafe) var textAntialias = true

    /// How the document is presented:
    ///   - `edit`    — live preview; the block under the caret reveals its raw
    ///                 markdown (the default editing experience).
    ///   - `reading` — everything rendered, no raw ever revealed; read-only.
    ///   - `source`  — plain monospaced raw markdown, no styling.
    public enum ViewMode: Sendable { case edit, reading, source }

    public var viewMode: ViewMode = .edit {
        didSet {
            guard oldValue != viewMode else { return }
            isEditable = (viewMode != .reading)
            if viewMode != .edit { clearCodeBlockControlHover() }
            // Re-style every block under the new mode (viewport-first for big docs).
            guard !blocks.isEmpty else { return }
            recomposeDirty(IndexSet(integersIn: 0..<blocks.count),
                           cursorInRaw: selectedRange().location)
        }
    }

    /// User overrides for callout styles, keyed by lowercased type. Lets a
    /// settings layer customize a built-in type's color / icon / border /
    /// background (or add new types). Empty by default (GitHub styles).
    public var calloutStyleOverrides: [String: CalloutStyle] = [:]

    /// Markdown extensions recognized by this editor. Changing the set reparses
    /// block structure as well as inline spans because some extensions merge
    /// multiple source lines into one rendering unit.
    public var markdownFeatures: MarkdownFeatures = .all {
        didSet {
            guard markdownFeatures != oldValue, !hasMarkedText() else { return }
            blocks = BlockParser.parse(rawSource, previous: blocks, features: markdownFeatures)
            recompose(cursorInRaw: currentCursorInRaw())
        }
    }

    /// When true (the default), edits and cursor moves keep the current line
    /// vertically centered (typewriter scrolling); when false, scrolling falls
    /// back to "keep the cursor visible". Toggled from the View menu. The
    /// scrolling logic lives in EditorTextView+TypewriterScroll.
    public var typewriterModeEnabled: Bool = true {
        didSet {
            guard oldValue != typewriterModeEnabled else { return }
            if !typewriterModeEnabled {
                minSize = NSSize(width: minSize.width, height: 0)
            }
        }
    }

    /// Set to true for the duration of a mouse-down event so that the
    /// resulting selection change does not trigger typewriter centering.
    /// Clicks position the caret where the user clicked — centering there
    /// would be jarring and is the root cause of the "glitchy" feeling.
    var suppressTypewriterCentering = false

    /// Physical maximum text-column width in points. Windows wider than this
    /// cap get symmetric side margins; narrower windows fill edge-to-edge.
    /// `.greatestFiniteMagnitude` means no cap (fill always). Set from the
    /// persisted cm value converted via the window's screen PPI. See
    /// EditorTextView+ContentWidth.
    public var maxContentWidthPoints: CGFloat = .greatestFiniteMagnitude {
        didSet {
            guard oldValue != maxContentWidthPoints else { return }
            updateContentInset()
        }
    }

    /// Whether a remote (`https`) image referenced by `![alt](url)` may load
    /// inline while editing. Mirrors Read mode's `allowRemoteImages`; set from
    /// `AppSettings.blockExternalImages`. Defaults off (the safe default until
    /// the app layer pushes the real setting in). See
    /// EditorTextView+ImageRendering for the load path.
    public var allowRemoteImages: Bool = false {
        didSet {
            guard oldValue != allowRemoteImages else { return }
            recomposeAllDirty()
        }
    }

    // MARK: - Derived Visual Properties

    /// The app accent: the macOS system accent (`controlAccentColor`), which
    /// resolves to the app's AccentColor asset — our brown — when the bundle
    /// ships the compiled asset catalog, and to the user's System Settings accent
    /// otherwise. Drives links, the checked-checkbox icon, the insertion point,
    /// and the selection tint so the editor matches the native AppKit controls.
    var accentColor: NSColor { .controlAccentColor }

    /// Foreground color for all body text. Uses the system text color so it
    /// flips automatically between near-black (light) and near-white (dark).
    var foregroundColor: NSColor { .textColor }

    /// Background tint for text selection. Uses system orange so selections read
    /// as warm amber rather than tracking the (potentially red) brand accent.
    var selectionHighlightColor: NSColor { .systemOrange.withAlphaComponent(0.3) }

    /// Background color for the editor surface. `.textBackgroundColor` is the
    /// standard semantic color for text-editing backgrounds (white / dark gray).
    private var editorBackgroundColor: NSColor { .textBackgroundColor }

    // MARK: - Font & Paragraph Style (derived from theme)

    public var bodyFont: NSFont { theme.bodyFont }

    var bodyParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = theme.lineSpacing
        ps.paragraphSpacingBefore = theme.paragraphSpacingBefore
        ps.paragraphSpacing = 0
        return ps
    }

    /// Apply a new theme and restyle every block in place. `persist: false`
    /// (used for zoom, which scales font sizes without changing the saved
    /// preference) applies the theme live without writing it to defaults.
    public func applyTheme(_ newTheme: EditorTheme, persist: Bool = true) {
        let antialiasChanged = theme.antialias != newTheme.antialias
        theme = newTheme
        if persist { theme.save(to: themeDefaults) }
        typingAttributes = baseAttributes
        recomposeAllDirty()
        // Antialiasing isn't a text attribute, so a recompose alone won't re-vend
        // the layout fragments — force a full re-layout when it changes.
        if antialiasChanged, let tlm = textLayoutManager {
            tlm.invalidateLayout(for: tlm.documentRange)
        }
        insertionPointColor = .clear
        fontHeightInsertionIndicator.color = accentColor
        scheduleFontHeightInsertionIndicatorUpdate()
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: foregroundColor,
            .paragraphStyle: bodyParagraphStyle,
        ]
    }

    var separatorLength: Int { (blockSeparator as NSString).length }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isRichText = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        // Completion and inline predictions inject provisional MARKED text as you
        // type (not just CJK/accent/emoji input). If such a composition is
        // interrupted — a caret move, a focus change — it can be left stranded
        // (`hasMarkedText()` stuck true), which permanently breaks the
        // storage==rawSource sync in `didChangeText` and drifts the caret on every
        // edit. A live-preview markdown editor needs neither, and we already
        // disable the other auto-substitutions
        // above — so close this marked-text source too.
        isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) { inlinePredictionType = .no }
        allowsUndo = false

        textAntialias = theme.antialias
        backgroundColor = editorBackgroundColor
        insertionPointColor = .clear
        fontHeightInsertionIndicator.color = accentColor
        fontHeightInsertionIndicator.displayMode = .hidden
        fontHeightInsertionIndicator.automaticModeOptions = []
        imageResizeChromeView.isHidden = true
        codeBlockLanguageOverlayView.editor = self
        codeBlockLanguageOverlayView.frame = bounds
        codeBlockLanguageOverlayView.autoresizingMask = [.width, .height]
        codeBlockControlView.isHidden = true
        codeBlockControlView.onCopy = { [weak self] in self?.copyHoveredCodeBlock() }
        addSubview(imageResizeChromeView)
        addSubview(codeBlockLanguageOverlayView)
        addSubview(codeBlockControlView)
        linkHoverHintView.isHidden = true
        addSubview(linkHoverHintView)
        addSubview(fontHeightInsertionIndicator)
        selectedTextAttributes = [
            .backgroundColor: selectionHighlightColor,
            .foregroundColor: foregroundColor,
        ]
        typingAttributes = baseAttributes

        rawSource = ""
        rebuildListIndentState()
        rebuildLinkDefState()
        blocks = BlockParser.parse(rawSource, features: markdownFeatures)
        recompose(cursorInRaw: 0)

        // Vend decoration-drawing layout fragments (TextKit 2).
        textLayoutManager?.delegate = self

        #if DEBUG
        // TextKit 1 fallback is silent and permanent: it happens when any
        // NSLayoutManager API is touched or an unsupported attribute (e.g.
        // NSTextBlock) enters the storage. Fail loudly instead.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textKit1FallbackTripwire(_:)),
            name: NSTextView.willSwitchToNSLayoutManagerNotification,
            object: self
        )
        #endif

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func rawLineStartOffsets() -> [Int] {
        guard !rawSource.isEmpty else { return [] }
        let utf16 = Array(rawSource.utf16)
        var starts = [0]
        for (index, value) in utf16.enumerated() where value == 0x0A {
            if index + 1 < utf16.count { starts.append(index + 1) }
        }
        return starts
    }

    private func applyGitChangeMarkers() {
        guard let storage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.gitChangeMarker, range: fullRange)
        storage.removeAttribute(.gitDeletionMarker, range: fullRange)
        guard storage.length > 0 else { return }
        let starts = rawLineStartOffsets()
        let source = rawSource as NSString
        for (lineIndex, kind) in gitChangeSet.lines where starts.indices.contains(lineIndex) {
            let start = starts[lineIndex]
            let lineRange = source.lineRange(for: NSRange(location: start, length: 0))
            let safeLength = max(1, min(lineRange.length, storage.length - start))
            storage.addAttribute(.gitChangeMarker, value: kind,
                                 range: NSRange(location: start, length: safeLength))
        }
        var deletionEdges: [Int: Set<GitDeletionEdge>] = [:]
        for boundary in gitChangeSet.deletionBoundaries where !starts.isEmpty {
            let lineIndex: Int
            let edge: GitDeletionEdge
            if boundary <= 0 {
                lineIndex = 0
                edge = .before
            } else {
                lineIndex = min(boundary - 1, starts.count - 1)
                edge = .after
            }
            deletionEdges[lineIndex, default: []].insert(edge)
        }
        for (lineIndex, edges) in deletionEdges {
            let start = starts[lineIndex]
            let lineRange = source.lineRange(for: NSRange(location: start, length: 0))
            let safeLength = max(1, min(lineRange.length, storage.length - start))
            storage.addAttribute(.gitDeletionMarker, value: edges,
                                 range: NSRange(location: start, length: safeLength))
        }
        needsDisplay = true
    }

    #if DEBUG
    @objc private func textKit1FallbackTripwire(_ note: Notification) {
        assertionFailure("""
        TextKit 1 fallback triggered — an NSLayoutManager API was called or an \
        unsupported attribute (NSTextBlock/NSTextTable?) entered the storage.
        """)
    }
    #endif

    /// Hook up scroll promotion once the editor lands in its scroll view.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installScrollPromotionObserver()
        if window == nil {
            stopFontHeightInsertionIndicator()
            hoveredLinkHit = nil
            hideLinkHoverHint()
            setAccessibilityHelp(nil)
        } else {
            scheduleFontHeightInsertionIndicatorUpdate()
        }
    }

    // MARK: - Appearance

    /// Re-render when the system appearance (light ↔ dark) changes.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = editorBackgroundColor
        insertionPointColor = .clear
        fontHeightInsertionIndicator.color = accentColor
        selectedTextAttributes = [
            .backgroundColor: selectionHighlightColor,
            .foregroundColor: foregroundColor,
        ]
        typingAttributes = baseAttributes
        recomposeAllDirty()
        codeBlockLanguageOverlayView.needsDisplay = true
        codeBlockControlView.needsDisplay = true
        scheduleFontHeightInsertionIndicatorUpdate()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        pointerTrackingArea = area
        addTrackingArea(area)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if let hit = hoveredLinkHit {
            addCursorRect(hit.cursorRect,
                          cursor: pointerModifierFlags.contains(.command) ? .pointingHand : .iBeam)
        }
        if let hit = hoveredImageOverlay {
            addCursorRect(imageResizeHandleRect(for: hit.frame), cursor: .resizeLeftRight)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateImageResizeHover(at: point)
        updateCodeBlockControlHover(at: point)
        super.mouseMoved(with: event)
        updatePointerHover(at: point, modifiers: event.modifierFlags)
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        pointerModifierFlags = event.modifierFlags
        // Cursor rects are normally reevaluated after pointer movement. A
        // modifier-only event has no movement, so synchronize immediately;
        // `set()` replaces state and cannot unbalance a global push/pop stack.
        if hoveredLinkHit != nil {
            window?.invalidateCursorRects(for: self)
            applyPointerCursor(at: lastPointerLocation, modifiers: event.modifierFlags)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        clearImageResizeHover()
        clearCodeBlockControlHover()
        hoveredLinkHit = nil
        hideLinkHoverHint()
        setAccessibilityHelp(nil)
        window?.invalidateCursorRects(for: self)
        super.mouseExited(with: event)
    }

    // MARK: - Link Following

    #if DEBUG
    /// Repro hook (ReproScript `clickoff`): move the caret to `offset` on the
    /// mouse path — i.e. with `suppressTypewriterCentering` set during the
    /// selection change, exactly as `mouseDown` does — so the caret-move
    /// restyle captures `fromMouse=true`. Lets a scripted replay reproduce the
    /// mouse-click branch without synthesizing HID events at screen coordinates.
    public func reproClickSelect(_ offset: Int) {
        suppressTypewriterCentering = true
        setSelectedRange(NSRange(location: min(offset, (rawSource as NSString).length), length: 0))
        suppressTypewriterCentering = false
    }
    #endif

    /// Cmd+click on a link's text follows it: a `[[wikilink]]` resolves to a
    /// file / heading, a regular link opens its URL. Any other click edits.
    /// Sets `suppressTypewriterCentering` for the duration of the super call so
    /// that the resulting selection change does not re-center the viewport —
    /// centering when the user merely clicks somewhere feels glitchy.
    public override func mouseDown(with event: NSEvent) {
        hideLinkHoverHint()
        let point = convert(event.locationInWindow, from: nil)
        // NSTextView may still claim mouseDown for an event-transparent child
        // view. Intercept the visible button before AppKit changes selection.
        if handleCodeBlockControlClick(at: point) { return }
        // Some input drivers deliver a click at a new location without a
        // preceding mouseMoved event. Refresh source-backed code chrome from
        // the click point so direct activation and ordinary hover agree.
        updateCodeBlockControlHover(at: point)
        if beginImageResizeIfNeeded(with: event) { return }
        clearImageResizeHover()
        if let action = linkNavigationAction(at: event) {
            perform(action)
            return
        }
        suppressTypewriterCentering = true
        super.mouseDown(with: event)
        suppressTypewriterCentering = false
    }

    enum LinkNavigationAction: Equatable {
        case wiki(String)
        case regular(String)
    }

    /// The sole click gate: without Command, a link deliberately produces no
    /// navigation action and NSTextView retains ordinary editing ownership.
    func linkNavigationAction(at event: NSEvent) -> LinkNavigationAction? {
        guard let index = clickCharIndex(at: event) else { return nil }
        return linkNavigationAction(atCharacterIndex: index,
                                    modifiers: event.modifierFlags)
    }

    func linkNavigationAction(atCharacterIndex index: Int,
                              modifiers: NSEvent.ModifierFlags) -> LinkNavigationAction?
    {
        guard modifiers.contains(.command), let storage = textStorage,
              index >= 0, index < storage.length else { return nil }
        if let target = storage.attribute(.editorWikiTarget, at: index,
                                          effectiveRange: nil) as? String {
            return .wiki(target)
        }
        if let destination = storage.attribute(.editorLinkURL, at: index,
                                               effectiveRange: nil) as? String {
            return .regular(destination)
        }
        return nil
    }

    private func perform(_ action: LinkNavigationAction) {
        switch action {
        case .wiki(let target): followWikiLink(target)
        case .regular(let destination): followLinkDestination(destination)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if updateImageResize(with: event) { return }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if finishImageResize(with: event) { return }
        super.mouseUp(with: event)
    }

    /// The storage character index directly under a mouse event, or nil if the
    /// click doesn't land on a laid-out glyph (e.g. past the end of a line).
    func clickCharIndex(at event: NSEvent) -> Int? {
        clickCharIndex(at: convert(event.locationInWindow, from: nil))
    }

    /// The storage character index directly under a point in view coordinates.
    func clickCharIndex(at pointInView: NSPoint) -> Int? {
        guard let tlm = textLayoutManager,
              let storage = textStorage, storage.length > 0 else { return nil }

        var point = pointInView
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y

        guard let fragment = tlm.textLayoutFragment(for: point) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let pointInFragment = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        // Reject clicks past the end of a line: typographic bounds cover only
        // the line's used extent.
        guard let line = fragment.textLineFragments.first(where: {
            $0.typographicBounds.contains(pointInFragment)
        }) else { return nil }

        let indexInParagraph = line.characterIndex(for: pointInFragment)
        guard indexInParagraph >= 0,
              let paraStart = fragment.textElement?.elementRange?.location else { return nil }
        let charIndex = tlm.offset(from: tlm.documentRange.location, to: paraStart) + indexInParagraph
        return charIndex < storage.length ? charIndex : nil
    }

    /// Re-evaluates link hover after the clip view scrolls under a stationary
    /// pointer. AppKit does not promise a new mouseMoved event for that case.
    func refreshPointerHoverFromWindow() {
        guard let window else { return }
        updatePointerHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil),
                           modifiers: NSEvent.modifierFlags)
    }

    var lastPointerLocation: NSPoint {
        guard let window else { return .zero }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    func updatePointerHover(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        pointerModifierFlags = modifiers
        let oldHit = hoveredLinkHit
        hoveredLinkHit = linkHoverHit(at: point)
        if oldHit != hoveredLinkHit { updateLinkHoverHint(from: oldHit) }
        if (oldHit == nil) != (hoveredLinkHit == nil) {
            setAccessibilityHelp(hoveredLinkHit == nil ? nil : linkNavigationHint)
        }
        if oldHit != hoveredLinkHit {
            window?.invalidateCursorRects(for: self)
        }
        applyPointerCursor(at: point, modifiers: modifiers)
    }

    private func updateLinkHoverHint(from oldHit: HoveredLinkHit?) {
        guard let hit = hoveredLinkHit else {
            hideLinkHoverHint()
            return
        }
        // Moving between wrapped segments of the same link should reposition
        // an already-visible hint, not hide and restart it.
        if oldHit?.range == hit.range, !linkHoverHintView.isHidden {
            linkHoverHintView.show(linkNavigationHint, near: hit.cursorRect, in: visibleRect)
            return
        }
        hideLinkHoverHint()
        let expectedRange = hit.range
        let work = DispatchWorkItem { [weak self] in
            self?.showLinkHoverHint(ifExpectedRange: expectedRange)
        }
        linkHintShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func showLinkHoverHint(ifExpectedRange expectedRange: NSRange) {
        guard hoveredLinkHit?.range == expectedRange,
              let currentHit = hoveredLinkHit else { return }
        linkHoverHintView.show(linkNavigationHint,
                               near: currentHit.cursorRect,
                               in: visibleRect)
    }

    private func hideLinkHoverHint() {
        linkHintShowWorkItem?.cancel()
        linkHintShowWorkItem = nil
        linkHoverHintView.isHidden = true
    }

    func applyPointerCursor(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        switch pointerCursorKind(at: point, modifiers: modifiers) {
        case .resizeLeftRight: NSCursor.resizeLeftRight.set()
        case .pointingHand: NSCursor.pointingHand.set()
        case .iBeam: NSCursor.iBeam.set()
        }
    }

    enum PointerCursorKind: Equatable {
        case resizeLeftRight
        case pointingHand
        case iBeam
    }

    func pointerCursorKind(at point: NSPoint,
                           modifiers: NSEvent.ModifierFlags) -> PointerCursorKind
    {
        if let image = hoveredImageOverlay,
           imageResizeHandleRect(for: image.frame).contains(point) {
            return .resizeLeftRight
        } else if hoveredLinkHit != nil, modifiers.contains(.command) {
            return .pointingHand
        } else {
            return .iBeam
        }
    }

    /// Link range plus the exact wrapped-line segment under `point`.
    func linkHoverHit(at pointInView: NSPoint) -> HoveredLinkHit? {
        guard let tlm = textLayoutManager, let storage = textStorage,
              let index = clickCharIndex(at: pointInView) else { return nil }
        var linkRange = NSRange()
        let hasLink = storage.attribute(.editorWikiTarget, at: index, effectiveRange: &linkRange) != nil
            || storage.attribute(.editorLinkURL, at: index, effectiveRange: &linkRange) != nil
        guard hasLink else { return nil }

        var point = pointInView
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        guard let fragment = tlm.textLayoutFragment(for: point),
              let paraStart = fragment.textElement?.elementRange?.location else { return nil }
        let paragraphOffset = tlm.offset(from: tlm.documentRange.location, to: paraStart)
        let frame = fragment.layoutFragmentFrame
        let pointInFragment = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard let line = fragment.textLineFragments.first(where: {
            $0.typographicBounds.contains(pointInFragment)
        }) else { return nil }

        let localLink = NSRange(location: linkRange.location - paragraphOffset,
                                length: linkRange.length)
        let segment = NSIntersectionRange(localLink, line.characterRange)
        guard segment.length > 0 else { return nil }
        let start = line.locationForCharacter(at: segment.location).x
        let end = line.locationForCharacter(at: segment.upperBound).x
        let x = textContainerOrigin.x + frame.minX + line.typographicBounds.minX + min(start, end)
        let y = textContainerOrigin.y + frame.minY + line.typographicBounds.minY
        let rect = NSRect(x: x, y: y, width: max(1, abs(end - start)),
                          height: line.typographicBounds.height)
        return HoveredLinkHit(range: linkRange, cursorRect: rect)
    }

    /// The raw destination string of the regular link under a mouse event, or
    /// nil if the click doesn't land directly on link text. The destination is
    /// resolved by `followLinkDestination` (external URL, `#heading`, or file).
    private func linkDestination(at event: NSEvent) -> String? {
        guard let storage = textStorage, let charIndex = clickCharIndex(at: event) else { return nil }
        return storage.attribute(.editorLinkURL, at: charIndex, effectiveRange: nil) as? String
    }

    // MARK: - Stranded-Composition Recovery

    /// Regaining first-responder status: recover from any stranded input-method
    /// composition. If a marked-text (IME / accent / emoji) composition is ever
    /// left uncommitted, `didChangeText` keeps bailing on its `hasMarkedText()`
    /// guard, so the text storage drifts away from `rawSource` and every edit
    /// then does offset math against a frozen block model — the "delete drift"
    /// bug. Returning focus is a reliable "composition is over" signal (the view
    /// can't become first responder while it already holds an active
    /// composition), so when the invariant is broken here we commit any stranded
    /// marked text and resync the model from the storage the user actually sees.
    /// This formalizes the focus-switch recovery users already stumble into.
    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            recoverFromStrandedCompositionIfNeeded()
            scheduleFontHeightInsertionIndicatorUpdate()
        }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        stopFontHeightInsertionIndicator()
        return super.resignFirstResponder()
    }

    /// Marked-text updates are not committed edits, so didChangeText correctly
    /// defers model sync. They still move the IME's internal insertion point;
    /// refresh only the foreground short caret after AppKit updates that state.
    public override func setMarkedText(_ string: Any,
                                       selectedRange: NSRange,
                                       replacementRange: NSRange) {
        super.setMarkedText(string,
                            selectedRange: selectedRange,
                            replacementRange: replacementRange)
        traceEdit("setMarkedText selected=\(selectedRange) replacement=\(replacementRange)")
        scheduleFontHeightInsertionIndicatorUpdate()
    }

    public override func unmarkText() {
        super.unmarkText()
        traceEdit("unmarkText")
        scheduleFontHeightInsertionIndicatorUpdate()
    }

    /// Window close and application termination can begin while an input method
    /// still owns provisional marked text. End the marking before NSDocument
    /// decides whether there is anything to save; otherwise `rawSource` may
    /// still look blank while storage contains the user's composition.
    public func commitMarkedTextForDocumentReview() {
        guard hasMarkedText() else { return }
        unmarkText()
        recoverFromStrandedCompositionIfNeeded()
    }

    func recoverFromStrandedCompositionIfNeeded() {
        guard let ts = textStorage, ts.string != rawSource else { return }
        // Rare and high-signal: this only fires when focus returns to a desynced
        // editor. The flag snapshot tells us *why* the sync was stranded the next
        // time the bug appears (marked text vs a leaked isUpdating/isUndoRedoing).
        Log.info("""
            recovered stranded desync on focus regain: hasMarked=\(hasMarkedText()) \
            isUpdating=\(isUpdating) isUndoRedoing=\(isUndoRedoing) \
            storageΔ=\((ts.string as NSString).length - (rawSource as NSString).length)
            """, category: .compose)
        if hasMarkedText() { unmarkText() }
        rawSource = ts.string
        rebuildListIndentState()
        rebuildLinkDefState()
        blocks = BlockParser.parse(rawSource, previous: blocks, features: markdownFeatures)
        recompose(cursorInRaw: min(selectedRange().location, (rawSource as NSString).length))
        let startsUndoGroup = consumePendingDocumentChangeGroupStart()
        publishSynchronizedTextChange(
            startsUndoGroup || document?.isDocumentEdited == false ? .changeDone : nil
        )
    }

    // MARK: - Helpers

    func currentCursorInRaw() -> Int {
        return selectedRange().location
    }

    /// Detects the indentation unit (columns per nesting level) used by list
    /// items in `source`: the smallest positive leading-space count, or 4 when
    /// tabs are used (a tab counts as one level) or nothing is found.
    static func detectListIndentUnit(_ source: String) -> Int {
        var minSpaces = Int.max
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var spaces = 0
            var sawTab = false
            for ch in line {
                if ch == " " { spaces += 1 }
                else if ch == "\t" { sawTab = true; break }
                else { break }
            }
            let rest = line.drop(while: { $0 == " " || $0 == "\t" })
            guard startsWithListMarker(rest) else { continue }
            if sawTab { return 4 }
            if spaces > 0 { minSpaces = min(minSpaces, spaces) }
        }
        return minSpaces == Int.max ? 4 : minSpaces
    }

    nonisolated static func startsWithListMarker(_ s: Substring) -> Bool {
        guard let first = s.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            return s.dropFirst().first == " "
        }
        if first.isNumber {
            let afterDigits = s.drop(while: { $0.isNumber })
            if let d = afterDigits.first, d == "." || d == ")" {
                return afterDigits.dropFirst().first == " "
            }
        }
        return false
    }

    // MARK: - Content Loading (called by Document)

    /// Replace the editor's content. Used by NSDocument on file open.
    public func loadContent(_ content: String) {
        replaceLoadedContent(content, selection: NSRange(location: 0, length: 0))
    }

    /// Replace content after the file changed on disk while keeping the user's
    /// selection at the nearest still-valid offsets. A reload is a new disk
    /// baseline, so stale undo snapshots must not survive it.
    @discardableResult
    public func reloadContent(_ content: String) -> Bool {
        // A full storage replacement during marked-text composition can strand
        // the input context. The document retries after composition commits.
        guard !hasMarkedText() else { return false }

        let oldSelection = selectedRange()
        stabilizingViewport {
            replaceLoadedContent(content, selection: oldSelection)
        }
        return true
    }

    private func replaceLoadedContent(_ content: String, selection: NSRange) {
        Log.measure("Loaded document (\(content.count) chars)", category: .document) {
            // Remember the file's line ending, then normalize the buffer to LF so
            // block parsing and rendering never see a stray `\r`. A file that mixes
            // styles is normalized to LF on save too (rather than its dominant style),
            // so its endings become consistent.
            originalLineEnding = LineEnding.isInconsistent(in: content) ? .lf : LineEnding.detect(in: content)
            rawSource = LineEnding.normalize(content)
            rebuildListIndentState()
            rebuildLinkDefState()
            blocks = BlockParser.parse(rawSource, features: markdownFeatures)
            Log.blockStructure(blocks)
            undoStack.removeAll()
            redoStack.removeAll()
            pendingDocumentChangeGroupStart = false
            lastEditType = .other
            lastEditBlockIndex = nil
            let length = (rawSource as NSString).length
            let location = min(selection.location, length)
            let clampedSelection = NSRange(
                location: location,
                length: min(selection.length, length - location)
            )
            recompose(cursorInRaw: location,
                      selectionInRaw: clampedSelection.length > 0 ? clampedSelection : nil)
        }
    }
}

// MARK: - String UTF-16 Index Helper

extension String {
    func utf16Index(at offset: Int) -> String.Index {
        return String.Index(utf16Offset: offset, in: self)
    }
}

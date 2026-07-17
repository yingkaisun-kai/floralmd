import AppKit
import FloralMDCore

/// Temporarily hosts a document's existing view hierarchy in the AppKit role
/// that can accompany another app's native full-screen window. The editor and
/// its storage are moved, never copied, so document, undo, selection, and IME
/// state keep a single owner.
@MainActor
final class AllSpacesPinnedPanelController: NSWindowController, NSWindowDelegate {
    unowned let documentWindow: DocumentWindow
    private let documentContentView: NSView
    private weak var editor: EditorTextView?
    private weak var originalFirstResponder: NSResponder?
    private let placeholder: NSView
    private var originalToolbar: NSToolbar?
    private let originalAccessories: [NSTitlebarAccessoryViewController]
    private var originalWindowAlpha: CGFloat
    private var originalIgnoresMouseEvents: Bool
    private var isSynchronizingFrame = false

    weak var ownerDocument: Document?

    private(set) var isPresented = false
    private(set) var documentWindows: [DocumentWindow]

    var panel: AllSpacesPinnedPanel {
        window as! AllSpacesPinnedPanel
    }

    init(documentWindow: DocumentWindow,
         contentView: NSView,
         editor: EditorTextView,
         titlebarAccessories: [NSTitlebarAccessoryViewController],
         tabbingIdentifier: String) {
        self.documentWindow = documentWindow
        documentContentView = contentView
        self.editor = editor
        originalFirstResponder = nil
        placeholder = NSView(frame: contentView.frame)
        placeholder.autoresizingMask = [.width, .height]
        originalToolbar = documentWindow.toolbar
        originalAccessories = titlebarAccessories
        originalWindowAlpha = documentWindow.alphaValue
        originalIgnoresMouseEvents = documentWindow.ignoresMouseEvents
        let groupedWindows = documentWindow.tabGroup?.windows
            ?? documentWindow.tabbedWindows
            ?? [documentWindow]
        documentWindows = groupedWindows.compactMap { $0 as? DocumentWindow }

        // NSWindow's initializer expects screen coordinates. contentLayoutRect
        // is window-local and would seed AppKit's tab grouping near (0, 0).
        let initialContentRect = documentWindow.contentRect(forFrameRect: documentWindow.frame)
        let panel = AllSpacesPinnedPanel(
            contentRect: initialContentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let presentation = PinnedWindowPresentationPolicy.allSpacesAuxiliaryPresentation
        panel.level = presentation.floatsAboveNormalWindows ? .floating : .normal
        var collectionBehavior: NSWindow.CollectionBehavior = []
        if presentation.joinsAllSpaces {
            collectionBehavior.insert(.canJoinAllSpaces)
        }
        if presentation.actsAsFullScreenAuxiliary {
            collectionBehavior.insert(.fullScreenAuxiliary)
        }
        panel.collectionBehavior = collectionBehavior
        panel.tabbingMode = .preferred
        panel.tabbingIdentifier = tabbingIdentifier
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = documentWindow.titleVisibility
        panel.titlebarAppearsTransparent = documentWindow.titlebarAppearsTransparent
        panel.titlebarSeparatorStyle = documentWindow.titlebarSeparatorStyle
        panel.toolbarStyle = documentWindow.toolbarStyle
        panel.isMovableByWindowBackground = documentWindow.isMovableByWindowBackground
        panel.minSize = documentWindow.minSize
        panel.backgroundColor = documentWindow.backgroundColor
        panel.viewModeButton = documentWindow.viewModeButton
        panel.makeViewModeMenu = documentWindow.makeViewModeMenu

        super.init(window: panel)
        panel.delegate = self
        panel.onRequestFullScreen = { [weak self] sender in
            self?.ownerDocument?.requestOwnFullScreen(sender)
        }
    }

    required init?(coder: NSCoder) { nil }

    func present(in document: Document, tabbingIdentifier: String, activate: Bool) {
        guard !isPresented else { return }
        isPresented = true
        ownerDocument = document
        originalFirstResponder = documentWindow.firstResponder
        originalToolbar = documentWindow.toolbar
        originalWindowAlpha = documentWindow.alphaValue
        originalIgnoresMouseEvents = documentWindow.ignoresMouseEvents
        let groupedWindows = documentWindow.tabGroup?.windows
            ?? documentWindow.tabbedWindows
            ?? [documentWindow]
        documentWindows = groupedWindows.compactMap { $0 as? DocumentWindow }
        panel.tabbingIdentifier = tabbingIdentifier

        // Keep the panel in the document's responder/save lifecycle. The empty
        // ordinary host stays in its native tab group; ordering it out can make
        // AppKit detach the group and may terminate the app at the last window.
        document.addWindowController(self)
        transferAccessories(from: documentWindow, to: panel)
        documentWindow.toolbar = nil
        panel.toolbar = originalToolbar
        panel.setFrame(documentWindow.frame, display: false)

        documentWindow.contentView = placeholder
        panel.contentView = documentContentView
        synchronizeWindowTitleWithDocumentName()
        panel.subtitle = documentWindow.subtitle
        panel.contentView?.layoutSubtreeIfNeeded()
        documentWindow.alphaValue = 0
        documentWindow.ignoresMouseEvents = true
        if activate {
            activatePanel()
        }
        Log.info("All-Spaces auxiliary panel presented", category: .app)
    }

    func activatePanel() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
    }

    func dismiss(restoringDocumentWindow: Bool) {
        guard isPresented else { return }
        isPresented = false

        let finalFrame = panel.frame
        panel.orderOut(nil)
        panel.contentView = NSView(frame: .zero)
        panel.toolbar = nil
        transferAccessories(from: panel, to: documentWindow)
        documentWindow.toolbar = originalToolbar
        documentWindow.contentView = documentContentView
        documentWindow.setFrame(finalFrame, display: false)
        documentWindow.alphaValue = originalWindowAlpha
        documentWindow.ignoresMouseEvents = originalIgnoresMouseEvents

        if restoringDocumentWindow {
            documentWindow.makeKeyAndOrderFront(nil)
            if let responder = originalFirstResponder ?? editor {
                documentWindow.makeFirstResponder(responder)
            }
        }

        if let ownerDocument {
            ownerDocument.removeWindowController(self)
        }
        ownerDocument = nil
        Log.info(
            "All-Spaces auxiliary panel cached: restored=\(restoringDocumentWindow)",
            category: .app
        )
    }

    func represents(documentWindows windows: [DocumentWindow]) -> Bool {
        Set(documentWindows.map(ObjectIdentifier.init)) == Set(windows.map(ObjectIdentifier.init))
    }

    func updateDocumentWindows(_ windows: [DocumentWindow]) {
        documentWindows = windows
    }

    func preserveDocumentWindowPresentationForDismissal(alpha: CGFloat,
                                                          ignoresMouseEvents: Bool) {
        originalWindowAlpha = alpha
        originalIgnoresMouseEvents = ignoresMouseEvents
    }

    func invalidateCache() {
        precondition(!isPresented)
        let cachedPanel = panel
        cachedPanel.delegate = nil
        cachedPanel.onRequestFullScreen = nil
        cachedPanel.orderOut(nil)
        cachedPanel.tabGroup?.removeWindow(cachedPanel)
        window = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        ownerDocument?.close()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        synchronizeDocumentWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        synchronizeDocumentWindowFrame()
    }

    private func synchronizeDocumentWindowFrame() {
        guard isPresented, !isSynchronizingFrame else { return }
        isSynchronizingFrame = true
        documentWindow.setFrame(panel.frame, display: false)
        isSynchronizingFrame = false
    }

    private func transferAccessories(from source: NSWindow, to destination: NSWindow) {
        for accessory in originalAccessories {
            if let index = source.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                source.removeTitlebarAccessoryViewController(at: index)
            }
            destination.addTitlebarAccessoryViewController(accessory)
        }
    }
}

final class AllSpacesPinnedPanel: NSPanel {
    weak var viewModeButton: NSView?
    var makeViewModeMenu: (() -> NSMenu)?
    var onRequestFullScreen: ((Any?) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func toggleFullScreen(_ sender: Any?) {
        onRequestFullScreen?(sender)
    }

    override func sendEvent(_ event: NSEvent) {
        if isSecondaryClick(event), let button = viewModeButton,
           button.bounds.contains(button.convert(event.locationInWindow, from: nil)),
           let menu = makeViewModeMenu?() {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        super.sendEvent(event)
    }

    private func isSecondaryClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown: return true
        case .leftMouseDown: return event.modifierFlags.contains(.control)
        default: return false
        }
    }
}

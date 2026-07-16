import AppKit
import UniformTypeIdentifiers
import FloralMDCore

/// NSDocument subclass that provides standard macOS document lifecycle:
/// file open/save, dirty-dot indicator, click-to-rename in the titlebar,
/// recent documents, and more — all for free.
///
/// The actual editing is delegated entirely to `EditorTextView`.
class Document: NSDocument, HeadingNavigable, OpenDocumentFileMoving {

    var editor: EditorTextView!
    private(set) var isQuickCapture = false
    private var suppressWindowSizePersistence = false
    private var statusBar: StatusBarView!
    private var outlineSidebar: OutlineSidebarView!
    private var navigationSidebar: DocumentNavigationSidebarView!
    private var minimapView: DocumentMinimapView!
    private var viewModeButton: NSButton?
    private var sidebarControlsAccessory: NSTitlebarAccessoryViewController?
    private var outlineSidebarButton: NSButton?
    private var navigationSidebarButton: NSButton?
    private static let viewModeItemID = NSToolbarItem.Identifier("viewMode")

    /// Session-only zoom scale (View ▸ Actual Size/Zoom In/Zoom Out), applied on
    /// top of the persisted font size and content width. Not saved — each new
    /// window starts back at 100%.
    private var zoomFactor: CGFloat = 1.0
    private static let zoomStep: CGFloat = 0.1
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...3.0

    /// Editor scroll view and its container, held so Read mode can swap the
    /// editor out for a `ReadModeWebView` (created lazily on first read).
    private var scrollView: NSScrollView!
    private var containerView: NSView!
    private var readView: ReadModeWebView?
    private var gitBaseline: GitFileBaseline?
    private var usesTranslucentPinnedWindowBackground = false

    /// Content loaded from disk before the editor window exists.
    /// `nonisolated(unsafe)` because `read(from:ofType:)` may be called
    /// off the main actor, but the value is only consumed on main via `showWindows`.
    nonisolated(unsafe) var pendingContent: String?

    /// Latest coordinated disk contents waiting for IME composition or an
    /// already-visible conflict sheet to finish.
    private var pendingExternalContent: String?
    private var isPresentingExternalConflict = false
    private var externalFileMonitor: ExternalFileMonitor?
    private var activeOwnFileWrites = 0
    private var shouldCheckExternalFileAfterOwnWrites = false
    private var mostRecentOwnWriteSnapshot: DocumentOwnWriteSnapshot?
    private var savePresentation: DocumentSavePresentation = .idle
    private var isSavingForClose = false
    private var untitledSaveState = UntitledDocumentSaveState()
    private var untitledSaveWorkItem: DispatchWorkItem?
    private var untitledSaveGeneration = 0
    private var hasPresentedUntitledSaveFailure = false
    private var sidebarSessionState = DocumentSidebarSessionState()

    override var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated {
                    if self?.fileURL != nil { self?.cancelScheduledUntitledSave() }
                    self?.restartExternalFileMonitor()
                }
            }
        }
    }

    // MARK: - Type Registration
    //
    // Without an Info.plist (SPM executable), NSDocument's default readableTypes
    // and writableTypes are empty, which causes NSDocumentController to disable
    // Open/Save entirely. We override them here.

    override class var readableTypes: [String] {
        ["public.plain-text", "net.daringfireball.markdown"]
    }

    override class var writableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text"]
    }

    override class var autosavesInPlace: Bool {
        AppSettings.autoSaveWithVersions
    }

    /// `EditorTextView` reports every committed edit through this method.
    /// Refresh the native tab here instead of relying only on AppKit to relay
    /// the dirty transition through `NSWindowController`.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        if savePresentation != .saving {
            setSavePresentation(isDocumentEdited ? .unsaved : cleanSavePresentation)
        }
        (windowControllers.first as? DocumentWindowController)?
            .refreshTabUnsavedIndicator()
    }

    override func updateChangeCount(withToken changeCountToken: Any,
                                    for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        reconcileDirtyStateWithDisk(reason: "save-token")
    }

    override func canClose(withDelegate delegate: Any,
                           shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        reconcileDirtyStateWithDisk(reason: "close")
        if DocumentSavePolicy.shouldBypassCloseReview(
            automaticSavingEnabled: AppSettings.autoSaveWithVersions,
            hasFileURL: fileURL != nil,
            persistedContentMatchesEditor: fileURL.map(contentsOnDiskMatchEditor(at:)) ?? false
        ), finishCanClose(withDelegate: delegate,
                          shouldClose: shouldCloseSelector,
                          contextInfo: contextInfo) {
            return
        }

        guard !isSavingForClose,
              let url = fileURL,
              DocumentSavePolicy.shouldSaveBeforeClosing(
                automaticSavingEnabled: AppSettings.autoSaveWithVersions,
                hasFileURL: true,
                isDocumentEdited: isDocumentEdited,
                hasUnautosavedChanges: hasUnautosavedChanges
              ) else {
            continueCanClose(withDelegate: delegate,
                             shouldClose: shouldCloseSelector,
                             contextInfo: contextInfo)
            return
        }

        isSavingForClose = true
        let typeName = fileType ?? "net.daringfireball.markdown"
        save(to: url, ofType: typeName, for: .autosaveInPlaceOperation) { [weak self] error in
            guard let self else { return }
            // NSDocument invokes this completion on the main thread after its
            // save token has been applied; the token override above performs
            // the first reconciliation, and this closes the loop before close.
            self.isSavingForClose = false
            self.reconcileDirtyStateWithDisk(reason: "close-save")
            let diskMatchesEditor = self.fileURL
                .map(self.contentsOnDiskMatchEditor(at:)) ?? false
            if error == nil,
               DocumentSavePolicy.shouldBypassCloseReview(
                automaticSavingEnabled: AppSettings.autoSaveWithVersions,
                hasFileURL: self.fileURL != nil,
                persistedContentMatchesEditor: diskMatchesEditor
               ), self.finishCanClose(withDelegate: delegate,
                                      shouldClose: shouldCloseSelector,
                                      contextInfo: contextInfo) {
                return
            }
            self.continueCanClose(withDelegate: delegate,
                                  shouldClose: shouldCloseSelector,
                                  contextInfo: contextInfo)
        }
    }

    private func finishCanClose(withDelegate delegate: Any,
                                shouldClose shouldCloseSelector: Selector?,
                                contextInfo: UnsafeMutableRawPointer?) -> Bool {
        guard let delegate = delegate as? NSObject,
              let shouldCloseSelector,
              delegate.responds(to: shouldCloseSelector) else { return false }
        typealias CloseCallback = @convention(c) (
            AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?
        ) -> Void
        let callback = unsafeBitCast(delegate.method(for: shouldCloseSelector),
                                     to: CloseCallback.self)
        callback(delegate, shouldCloseSelector, self, true, contextInfo)
        return true
    }

    private func continueCanClose(withDelegate delegate: Any,
                                  shouldClose shouldCloseSelector: Selector?,
                                  contextInfo: UnsafeMutableRawPointer?) {
        super.canClose(withDelegate: delegate,
                       shouldClose: shouldCloseSelector,
                       contextInfo: contextInfo)
    }

    func saveBeforeAutomaticTermination(completion: @escaping (Error?) -> Void) {
        reconcileDirtyStateWithDisk(reason: "termination-review")
        guard let url = fileURL,
              isDocumentEdited || hasUnautosavedChanges else {
            completion(nil)
            return
        }

        let typeName = fileType ?? "net.daringfireball.markdown"
        save(to: url, ofType: typeName, for: .autosaveInPlaceOperation) { [weak self] error in
            self?.reconcileDirtyStateWithDisk(reason: "termination-save")
            completion(error)
        }
    }

    override class func isNativeType(_ name: String) -> Bool {
        return readableTypes.contains(name)
    }

    // A single writable type keeps the save panel from showing a file-format
    // popup. Everything we write is markdown, so there's nothing to choose.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        ["net.daringfireball.markdown"]
    }

    // The `net.daringfireball.markdown` UTI prefers the ".markdown" extension;
    // force ".md" instead, which is what people actually expect.
    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        "md"
    }

    // `fileNameExtension(forType:…)` alone isn't enough: for an untitled save
    // the panel still seeds its name field from the markdown UTI's preferred
    // extension (".markdown"). Force the default name to end in ".md" and let
    // the user type any other extension if they really want one.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = []
        savePanel.allowsOtherFileTypes = true
        let base = (savePanel.nameFieldStringValue as NSString).deletingPathExtension
        savePanel.nameFieldStringValue = (base.isEmpty ? AppCopy.text("Untitled", "未命名") : base) + ".md"
        return true
    }

    // MARK: - Window Setup

    override func makeWindowControllers() {
        // Default content size for first launch. Any saved size is applied as a
        // full window frame at the end of setup (below), once the toolbar is in
        // place — so the frame round-trips exactly and doesn't drift by the
        // title bar + toolbar height each time.
        let windowWidth: CGFloat = 800
        let windowHeight: CGFloat = 560

        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        // Keep full-screen available after the window moves to `.floating`;
        // AppKit otherwise turns the standard green button into Zoom and
        // disables Window ▸ Enter Full Screen before our suspension hook runs.
        window.collectionBehavior.insert(.fullScreenPrimary)
        // A compact capture is a transient entry surface, not another tab in a
        // full-size document group. Decide this before the window is shown so
        // AppKit cannot auto-merge it and shrink an ordinary document window.
        if isQuickCapture {
            window.tabbingMode = .disallowed
        }
        window.level = .normal
        // Don't persist/restore document windows: macOS state restoration
        // otherwise reopens the last-edited file on the next launch, so a fresh
        // start (or File ▸ New) shows that document instead of a blank Untitled.
        window.isRestorable = AppSettings.reopenWindows
        window.minSize = QuickCapturePolicy.compactWindowSize
        window.backgroundColor = NSColor.textBackgroundColor

        // Build the TextKit 2 text system chain (viewport-based layout).
        editor = EditorTextView.makeTextKit2(
            frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            containerSize: NSSize(width: windowWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.usesFindPanel = true
        editor.isIncrementalSearchingEnabled = true
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 24, height: 18)
        // Centered reading column (see EditorTextView+ContentWidth). Convert the
        // persisted cm value to points using the main screen PPI at window-creation
        // time; recomputed on resize (setFrameSize) and when the window moves to a
        // different display (windowDidChangeScreen).
        let initScreen = NSScreen.main
        editor.maxContentWidthPoints = initScreen?.cmToPoints(AppSettings.maxContentWidthCm) ?? 1000
        editor.updateContentInset()
        editor.allowRemoteImages = !AppSettings.blockExternalImages
        editor.typewriterModeEnabled = AppSettings.typewriterMode
        editor.document = self

        // Toolbar holds the right-aligned view-mode toggle (and gives the
        // titlebar extra height for roomy traffic lights). Set it only after
        // `editor` exists — assigning the toolbar synchronously vends its items.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true   // persists layout per "MainToolbar"
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line
        installSidebarControlsAccessory(in: window)

        // Wire the window's secondary-click interception now that the toolbar has
        // synchronously vended the view-mode button (see DocumentWindow).
        window.viewModeButton = viewModeButton
        window.makeViewModeMenu = { [weak self] in self?.viewModeMenu() ?? NSMenu() }

        let statusBarHeight: CGFloat = 22
        let contentBounds = window.contentView!.bounds

        // The text view fills the whole window; the status bar floats over its
        // bottom edge, revealed on hover.
        let navigationWidth = sidebarSessionState.isNavigationExpanded
            ? DocumentNavigationSidebarView.expandedWidth
            : DocumentNavigationSidebarView.collapsedWidth
        let outlineWidth = sidebarSessionState.isOutlineExpanded
            ? OutlineSidebarView.expandedWidth
            : OutlineSidebarView.collapsedWidth
        let minimapWidth = AppSettings.showMinimap ? DocumentMinimapView.width : 0
        let initialLayout = DocumentPaneLayout(contentSize: contentBounds.size,
                                               navigationSidebarWidth: navigationWidth,
                                               outlineSidebarWidth: outlineWidth,
                                               minimapWidth: minimapWidth,
                                               statusBarHeight: statusBarHeight)
        scrollView = NSScrollView(frame: initialLayout.editorFrame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = editor

        minimapView = DocumentMinimapView(frame: initialLayout.minimapFrame)
        minimapView.autoresizingMask = [.height]
        minimapView.editor = editor
        minimapView.scrollView = scrollView
        minimapView.isHidden = !AppSettings.showMinimap
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Floating status bar: hidden by default, fades in when the pointer
        // enters its strip. Counts on the left, line ending on the right.
        statusBar = StatusBarView(frame: initialLayout.statusFrame)
        statusBar.autoresizingMask = [.width]

        containerView = DocumentContainerView(frame: contentBounds)
        containerView.autoresizesSubviews = true
        navigationSidebar = DocumentNavigationSidebarView(
            frame: initialLayout.navigationSidebarFrame
        )
        navigationSidebar.onOpenFile = { [weak self] url in
            guard let self, let controller = NSDocumentController.shared as? DocumentController else { return }
            controller.openDocumentTab(at: url, from: self)
        }
        navigationSidebar.onRenameFile = { [weak self] url, proposedStem, completion in
            guard let self,
                  let controller = NSDocumentController.shared as? DocumentController else { return }
            controller.renameFile(at: url,
                                  proposedStem: proposedStem,
                                  from: self,
                                  completion: completion)
        }
        navigationSidebar.onWidthChange = { [weak self] width, duration in
            guard let self else { return }
            self.sidebarSessionState.setNavigationExpanded(
                width == DocumentNavigationSidebarView.expandedWidth
            )
            self.refreshSidebarControlAppearance()
            self.updateDocumentLayout(navigationSidebarWidth: width,
                                      outlineSidebarWidth: self.currentOutlineWidth,
                                      duration: duration)
        }
        containerView.addSubview(scrollView)
        containerView.addSubview(minimapView)
        containerView.addSubview(statusBar)   // overlay, on top of the text
        containerView.addSubview(navigationSidebar)
        outlineSidebar = OutlineSidebarView()
        outlineSidebar.onSelectHeading = { [weak self] heading in
            self?.editor.scrollToHeading(heading)
        }
        outlineSidebar.onWidthChange = { [weak self] width, duration in
            guard let self else { return }
            self.sidebarSessionState.setOutlineExpanded(
                width == OutlineSidebarView.expandedWidth
            )
            self.refreshSidebarControlAppearance()
            self.updateDocumentLayout(navigationSidebarWidth: self.currentNavigationWidth,
                                      outlineSidebarWidth: width,
                                      duration: duration)
        }
        containerView.addSubview(outlineSidebar)
        outlineSidebar.installConstraints(in: containerView, leadingOffset: navigationWidth)
        // This is a one-time window-session default. Later refreshes never
        // reapply it, so either sidebar stays open after the user expands it.
        outlineSidebar.setExpanded(sidebarSessionState.isOutlineExpanded, animated: false)
        navigationSidebar.setExpanded(sidebarSessionState.isNavigationExpanded, animated: false)

        window.contentView = containerView

        NotificationCenter.default.addObserver(
            self, selector: #selector(editorDidChange(_:)),
            name: NSText.didChangeNotification, object: editor
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorDidSynchronizeText(_:)),
            name: .editorDidSynchronizeText, object: editor
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: editor
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorViewportDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentsDidChange(_:)),
            name: DocumentController.documentsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(untitledAutoSaveSettingsDidChange(_:)),
            name: .untitledAutoSaveSettingsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshGitChangeMarkers),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        // Restore the last window's frame size (the toolbar is now installed, so
        // the frame is final). Applied as a frame, not a contentRect, so it
        // round-trips exactly with what windowDidResize saves. Then center.
        if !isQuickCapture, let savedSize = AppSettings.lastWindowSize {
            window.setFrame(NSRect(origin: window.frame.origin, size: savedSize), display: false)
        }
        window.center()
        if isQuickCapture {
            applyCompactWindowFrame(to: window, display: false)
        }

        let wc = DocumentWindowController(window: window)
        addWindowController(wc)
        refreshWindowTitle()
        setSavePresentation(cleanSavePresentation)
        window.makeFirstResponder(editor)
        // Honor the persisted source-mode preference for the editing view.
        if AppSettings.sourceMode { setViewMode(.source) }
        updateStatusBar()
        updateOutline()
        refreshNavigationSidebar()
    }

    /// Keep the editor and floating status strip entirely outside the outline's
    /// frame. Unlike the former overlay layout, this gives AppKit disjoint
    /// cursor regions: the outline owns an arrow and NSTextView owns its I-beam.
    private var currentOutlineWidth: CGFloat {
        outlineSidebar?.isExpanded == true
            ? OutlineSidebarView.expandedWidth : OutlineSidebarView.collapsedWidth
    }

    private var currentNavigationWidth: CGFloat {
        navigationSidebar?.isExpanded == true
            ? DocumentNavigationSidebarView.expandedWidth
            : DocumentNavigationSidebarView.collapsedWidth
    }

    private func updateDocumentLayout(navigationSidebarWidth: CGFloat,
                                      outlineSidebarWidth: CGFloat,
                                      duration: TimeInterval) {
        guard let containerView, let scrollView, let statusBar, let minimapView,
              let navigationSidebar, let outlineSidebar else { return }
        let minimapWidth = AppSettings.showMinimap ? DocumentMinimapView.width : 0
        let layout = DocumentPaneLayout(contentSize: containerView.bounds.size,
                                        navigationSidebarWidth: navigationSidebarWidth,
                                        outlineSidebarWidth: outlineSidebarWidth,
                                        minimapWidth: minimapWidth,
                                        statusBarHeight: statusBar.frame.height)
        outlineSidebar.setLeadingOffset(layout.outlineSidebarFrame.minX)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            scrollView.animator().frame = layout.editorFrame
            minimapView.animator().frame = layout.minimapFrame
            statusBar.animator().frame = layout.statusFrame
            navigationSidebar.animator().frame = layout.navigationSidebarFrame
            readView?.animator().frame = layout.readFrame
            containerView.layoutSubtreeIfNeeded()
        }
        minimapView.isHidden = !AppSettings.showMinimap || editor.viewMode == .reading
    }

    @objc private func documentsDidChange(_ notification: Notification) {
        refreshNavigationSidebar()
    }

    func refreshNavigationSidebar() {
        navigationSidebar?.refresh(currentFileURL: fileURL)
    }

    /// Refresh every document-owned label after the interface language changes.
    func refreshLocalizedInterface() {
        refreshWindowTitle()
        refreshSavePresentation()
        refreshViewModeButton()
        updateStatusBar()
        if let item = windowControllers.first?.window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.viewModeItemID }) {
            item.label = AppCopy.text("View Mode", "视图模式")
            item.paletteLabel = item.label
        }
        refreshSidebarControlAppearance()
    }

    func refreshShortcutPresentation() {
        refreshSidebarControlAppearance()
        refreshViewModeButton()
    }

    /// Stable controls beside the traffic lights toggle the primary repository
    /// sidebar and the outline attached to the editing surface. Neither drawer
    /// needs to retain a content-width rail merely to expose its toggle.
    private func installSidebarControlsAccessory(in window: NSWindow) {
        func makeButton(action: Selector) -> NSButton {
            let button = NSButton()
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
            return button
        }

        let outlineButton = makeButton(action: #selector(toggleOutlineSidebar(_:)))
        let navigationButton = makeButton(action: #selector(toggleNavigationSidebar(_:)))
        let controls = NSStackView(views: [navigationButton, outlineButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 64),
            container.heightAnchor.constraint(equalToConstant: 28),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controls.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.fullScreenMinHeight = 28
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
        sidebarControlsAccessory = accessory
        outlineSidebarButton = outlineButton
        navigationSidebarButton = navigationButton
        refreshSidebarControlAppearance()
    }

    private func refreshSidebarControlAppearance() {
        func update(_ button: NSButton?, symbol: String, description: String) {
            button?.image = NSImage(systemSymbolName: symbol,
                                    accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            button?.toolTip = description
            button?.setAccessibilityLabel(description)
        }

        let navigationDescription = withShortcut(
            sidebarSessionState.isNavigationExpanded
            ? AppCopy.text("Collapse file sidebar", "收起文件侧栏")
            : AppCopy.text("Expand file sidebar", "展开文件侧栏"),
            commandID: "view.toggleNavigationSidebar"
        )
        let outlineDescription = withShortcut(
            sidebarSessionState.isOutlineExpanded
            ? AppCopy.text("Collapse outline", "收起大纲")
            : AppCopy.text("Expand outline", "展开大纲"),
            commandID: "view.toggleOutlineSidebar"
        )
        update(navigationSidebarButton, symbol: "sidebar.left", description: navigationDescription)
        update(outlineSidebarButton, symbol: "list.bullet.indent", description: outlineDescription)
    }

    private func withShortcut(_ text: String, commandID: String) -> String {
        guard let shortcut = AppSettings.effectiveShortcut(for: commandID) else { return text }
        return "\(text) (\(shortcut.displayName))"
    }

    private func refreshWindowTitle() {
        guard fileURL == nil else { return }
        guard let controller = windowControllers.first,
              let window = controller.window else { return }
        window.title = AppCopy.text("Untitled", "未命名")
        (controller as? DocumentWindowController)?.refreshTabUnsavedIndicator()
    }

    private var cleanSavePresentation: DocumentSavePresentation {
        fileURL == nil ? .idle : .saved
    }

    fileprivate func documentEditedStateDidChange(_ dirty: Bool) {
        guard savePresentation != .saving else { return }
        setSavePresentation(dirty ? .unsaved : cleanSavePresentation)
    }

    private func setSavePresentation(_ presentation: DocumentSavePresentation) {
        savePresentation = presentation
        refreshSavePresentation()
    }

    private func refreshSavePresentation() {
        guard let window = windowControllers.first?.window else { return }
        window.subtitle = switch savePresentation {
        case .idle:
            ""
        case .unsaved:
            AppCopy.text("Not Saved", "未保存")
        case .saving:
            AppCopy.text("Saving…", "正在保存…")
        case .saved:
            AppCopy.text("Saved", "已保存")
        case .failed:
            AppCopy.text("Save Failed", "保存失败")
        }
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Save the full frame size; it's restored verbatim via setFrame on the
        // next window, so the size round-trips exactly (no title-bar/toolbar drift).
        // Quick Capture has its own fixed presentation and must never overwrite
        // the normal document-window default.
        if !isQuickCapture, !suppressWindowSizePersistence {
            AppSettings.lastWindowSize = window.frame.size
        }
        updateDocumentLayout(navigationSidebarWidth: currentNavigationWidth,
                             outlineSidebarWidth: currentOutlineWidth,
                             duration: 0)
    }

    /// Reapply the content-width cap in points when the window moves to a
    /// display with a different physical PPI (e.g. external monitor).
    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen else { return }
        editor?.maxContentWidthPoints = screen.cmToPoints(AppSettings.maxContentWidthCm) * zoomFactor
    }

    // MARK: - Window Level / Quick Capture

    var isWindowAlwaysOnTop: Bool {
        (windowControllers.first?.window as? DocumentWindow)?.isAlwaysOnTop == true
    }

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        setAlwaysOnTop(!isWindowAlwaysOnTop)
    }

    @objc func shrinkToMinimumWindow(_ sender: Any?) {
        guard let window = windowControllers.first?.window,
              !window.styleMask.contains(.fullScreen) else { return }
        suppressWindowSizePersistence = true
        applyCompactWindowFrame(to: window, display: true)
        DispatchQueue.main.async { [weak self] in
            self?.suppressWindowSizePersistence = false
        }
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        guard let window = windowControllers.first?.window else { return }
        let group = window.tabbedWindows ?? [window]
        for case let documentWindow as DocumentWindow in group {
            documentWindow.isAlwaysOnTop = enabled
        }
        refreshPinnedWindowPresentation()
    }

    func activateAsQuickCapture() {
        isQuickCapture = true
        if windowControllers.isEmpty {
            makeWindowControllers()
            showWindows()
        }
        setAlwaysOnTop(true)
        guard let window = windowControllers.first?.window else { return }
        outlineSidebar?.setExpanded(false, animated: false)
        navigationSidebar?.setExpanded(false, animated: false)
        applyCompactWindowFrame(to: window, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        refreshPinnedWindowPresentation()
    }

    private func applyCompactWindowFrame(to window: NSWindow, display: Bool) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let frame = QuickCapturePolicy.compactWindowFrame(
            around: window.frame,
            constrainedTo: visibleFrame
        )
        window.setFrame(frame, display: display)
    }

    /// AppKit represents each native tab as its own NSWindow. Normalize the
    /// group whenever a tab becomes key so a merged group cannot silently mix
    /// normal and floating levels.
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? DocumentWindow else { return }
        if let tabbedWindows = window.tabbedWindows {
            for case let tab as DocumentWindow in tabbedWindows {
                tab.isAlwaysOnTop = window.isAlwaysOnTop
            }
        }
        refreshPinnedWindowPresentation()
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        setAlwaysOnTopSuspendedForFullScreen(true, window: notification.object as? DocumentWindow)
        refreshPinnedWindowPresentation()
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        setAlwaysOnTopSuspendedForFullScreen(false, window: notification.object as? DocumentWindow)
        refreshPinnedWindowPresentation()
    }

    private func setAlwaysOnTopSuspendedForFullScreen(_ suspended: Bool,
                                                       window: DocumentWindow?) {
        guard let window else { return }
        let group = window.tabbedWindows ?? [window]
        for case let tab as DocumentWindow in group {
            if suspended {
                tab.suspendAlwaysOnTopForFullScreen()
            } else {
                tab.resumeAlwaysOnTopAfterFullScreen()
            }
        }
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        refreshPinnedWindowPresentation()
    }

    /// The window's alpha stays at 1 for all foreground content; only the content
    /// backgrounds stop drawing while the document window is pinned. This
    /// deliberately avoids `NSWindow.alphaValue`, which
    /// would also fade text, the caret, controls, images, and fragment overlays.
    private func refreshPinnedWindowPresentation() {
        guard let window = windowControllers.first?.window as? DocumentWindow else { return }
        let workspace = NSWorkspace.shared
        let opacity = PinnedWindowPresentationPolicy.backgroundOpacity(
            isAlwaysOnTop: window.isAlwaysOnTop,
            isFullScreen: window.styleMask.contains(.fullScreen),
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        let translucent = opacity < 1
        usesTranslucentPinnedWindowBackground = translucent

        if translucent { window.isOpaque = false }
        window.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(opacity)
        (containerView as? DocumentContainerView)?.drawsBackground = !translucent
        editor.drawsBackground = !translucent

        // A one-third local tint over the 88% window background yields an
        // effective opacity of about 92%, keeping navigation chrome quieter but
        // more legible than the editor canvas.
        let sidebarTintOpacity: CGFloat = translucent ? 1.0 / 3.0 : 1
        outlineSidebar.backgroundOpacity = sidebarTintOpacity
        navigationSidebar.backgroundOpacity = sidebarTintOpacity
        readView?.usesTransparentBackground = translucent

        if !translucent { window.isOpaque = true }
        window.invalidateShadow()
    }

    // MARK: - Zoom (View ▸ Actual Size / Zoom In / Zoom Out)

    @objc func zoomIn(_ sender: Any?) { setZoom(zoomFactor + Self.zoomStep) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoomFactor - Self.zoomStep) }
    @objc func actualSize(_ sender: Any?) { setZoom(1.0) }

    @objc func toggleOutlineSidebar(_ sender: Any?) {
        outlineSidebar?.toggleExpanded()
    }

    @objc func toggleNavigationSidebar(_ sender: Any?) {
        navigationSidebar?.toggleExpanded()
    }

    /// Scales font size (standard + code) and max content width together by
    /// `factor`, off the persisted base values — never off the currently
    /// applied (possibly already-zoomed) theme, so repeated zooming doesn't
    /// compound rounding error and Actual Size always returns to the true base.
    private func setZoom(_ factor: CGFloat) {
        guard let editor else { return }
        zoomFactor = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, factor))

        let base = EditorTheme.load(from: editor.themeDefaults)
        var zoomed = base
        zoomed.fontSize = base.fontSize * zoomFactor
        zoomed.monospaceFontSize = base.monospaceFontSize * zoomFactor
        editor.applyTheme(zoomed, persist: false)

        let screen = editor.window?.screen ?? NSScreen.main
        editor.maxContentWidthPoints = (screen?.cmToPoints(AppSettings.maxContentWidthCm) ?? 1000) * zoomFactor

        refreshReadView()
    }

    @objc private func editorDidChange(_ notification: Notification) {
        updateStatusBar()
        updateOutline()
        // Keep an open Read view in sync with edits (it renders a snapshot).
        refreshReadView()
        minimapView?.refresh()
    }

    @objc private func editorDidSynchronizeText(_ notification: Notification) {
        updateGitChangeMarkers()
        minimapView?.refresh()
        resolvePendingExternalChange()
        handleUntitledSaveInputChange()
    }

    @objc private func untitledAutoSaveSettingsDidChange(_ notification: Notification) {
        hasPresentedUntitledSaveFailure = false
        handleUntitledSaveInputChange()
    }

    private var isEligibleForUntitledSave: Bool {
        guard let editor else { return false }
        return UntitledDocumentSavePolicy.isEligible(
            enabled: AppSettings.autoSaveUntitledDocuments,
            hasFileURL: fileURL != nil,
            rawSource: editor.rawSource,
            hasMarkedText: editor.hasMarkedText()
        )
    }

    private func handleUntitledSaveInputChange() {
        switch untitledSaveState.inputChanged(isEligible: isEligibleForUntitledSave) {
        case .schedule:
            scheduleUntitledSave()
        case .cancel:
            cancelScheduledUntitledSave()
        case .none, .beginSave:
            break
        }
    }

    private func scheduleUntitledSave() {
        cancelScheduledUntitledSave()
        let delay = UntitledDocumentSavePolicy.debounceDelay(
            requestedInterval: AppSettings.autoSaveInterval
        )
        let generation = untitledSaveGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.untitledSaveGeneration == generation else { return }
            self.untitledSaveWorkItem = nil
            guard self.untitledSaveState.timerFired(
                isEligible: self.isEligibleForUntitledSave
            ) == .beginSave else { return }
            self.performUntitledSave()
        }
        untitledSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledUntitledSave() {
        untitledSaveGeneration &+= 1
        untitledSaveWorkItem?.cancel()
        untitledSaveWorkItem = nil
    }

    private func performUntitledSave() {
        // The timer is downstream of rawSource synchronization, but IME state
        // can change again before it fires. Never enter NSDocument saving while
        // marked text is active.
        guard isEligibleForUntitledSave, !editor.hasMarkedText() else {
            untitledSaveState.saveCompleted(success: false)
            return
        }
        guard let directoryAccess = AppSettings.accessUntitledDocumentDirectory() else {
            failUntitledSave(message: AppCopy.text(
                "The draft folder is unavailable. Choose it again in General settings.",
                "草稿文件夹不可用。请在“通用”设置中重新选择。"
            ))
            return
        }

        let reservation: UntitledDocumentFileReservation
        do {
            reservation = try UntitledDocumentFileReservation.reserve(in: directoryAccess.url)
        } catch {
            failUntitledSave(message: AppCopy.text(
                "FloralMD could not create a file in the selected draft folder. Your text is still open and unsaved.",
                "FloralMD 无法在所选草稿文件夹中创建文件。正文仍保留在当前未保存文档中。"
            ), underlying: error)
            return
        }

        let url = reservation.url
        save(to: url, ofType: "net.daringfireball.markdown", for: .saveAsOperation) {
            [weak self, directoryAccess] error in
            _ = directoryAccess // Keep future security-scoped access alive through completion.
            guard let self else { return }
            if let error {
                // AppKit may provisionally adopt the save-as destination before
                // the write finishes. A failed first save must remain Untitled
                // so the next committed edit can retry the configured workflow.
                if self.fileURL?.standardizedFileURL == url.standardizedFileURL {
                    self.fileURL = nil
                }
                reservation.removeIfEmpty()
                self.failUntitledSave(message: AppCopy.text(
                    "FloralMD could not save this draft automatically. Your text is still open and unsaved.",
                    "FloralMD 无法自动保存此草稿。正文仍保留在当前未保存文档中。"
                ), underlying: error)
                return
            }

            self.untitledSaveState.saveCompleted(success: true)
            self.hasPresentedUntitledSaveFailure = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            self.refreshGitChangeMarkers()
            self.refreshNavigationSidebar()
        }
    }

    private func failUntitledSave(message: String, underlying: Error? = nil) {
        untitledSaveState.saveCompleted(success: false)
        setSavePresentation(.failed)
        Log.error("Untitled first save failed: \(underlying?.localizedDescription ?? message)",
                  category: .io)
        guard !hasPresentedUntitledSaveFailure,
              let window = windowControllers.first?.window else { return }
        hasPresentedUntitledSaveFailure = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppCopy.text(
            "Draft Could Not Be Saved",
            "草稿无法保存"
        )
        alert.informativeText = message
        alert.addButton(withTitle: AppCopy.text("OK", "好"))
        alert.beginSheetModal(for: window)
    }

    @objc private func editorSelectionDidChange(_ notification: Notification) {
        updateStatusBar()
        minimapView?.refresh()
    }

    @objc private func editorViewportDidChange(_ notification: Notification) {
        minimapView?.refresh()
    }

    func refreshMinimapVisibility() {
        updateDocumentLayout(navigationSidebarWidth: currentNavigationWidth,
                             outlineSidebarWidth: currentOutlineWidth,
                             duration: 0.18)
        minimapView?.refresh()
    }

    /// Applies the global source-presentation preference without disturbing a
    /// document that is currently in Read mode. Its next return to the editing
    /// side will use the latest preference.
    func refreshSourceModePreference() {
        guard editor?.viewMode != .reading else { return }
        setViewMode(editingMode)
    }

    private func updateStatusBar() {
        guard let editor = editor, let statusBar = statusBar else { return }
        let text = editor.rawSource
        let nsText = text as NSString
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let charCount = text.count

        // Cursor position: 0-based character location and 1-based line number.
        let cursorOffset = editor.selectedRange().location
        let location = min(cursorOffset, nsText.length)
        let upToCursor = nsText.substring(to: location)
        let line = upToCursor.isEmpty ? 1 : upToCursor.components(separatedBy: "\n").count

        // The buffer is always LF; show the file's remembered original ending.
        statusBar.setMetrics(words: wordCount, characters: charCount,
                             location: location, line: line,
                             lineEnding: editor.originalLineEnding.displayName)
    }

    private func updateOutline() {
        outlineSidebar?.setItems(editor?.outlineItems() ?? [])
    }

    // MARK: - Reading

    /// NSDocument is already registered as an NSFilePresenter. AppKit reports
    /// coordinated writes here, but its default implementation does not apply
    /// our `pendingContent` to the live EditorTextView after the window exists.
    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                self?.checkForExternalFileChange()
            }
        }
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let contents = String(data: data, encoding: .utf8) else {
            Log.error("Read failed: \(data.count) bytes not valid UTF-8", category: .io)
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: AppCopy.text("Could not read file as UTF-8", "无法以 UTF-8 编码读取文件")])
        }
        Log.info("Read \(data.count) bytes from disk", category: .io)
        pendingContent = contents
    }

    /// Called after makeWindowControllers when opening an existing file.
    override func showWindows() {
        super.showWindows()
        if let content = pendingContent {
            editor?.loadContent(content)
            pendingContent = nil
            warnIfInconsistentLineEndings(in: content)
        }
        refreshGitChangeMarkers()
        updateStatusBar()
        updateOutline()
        refreshNavigationSidebar()
        restartExternalFileMonitor()
    }

    @objc private func refreshGitChangeMarkers() {
        gitBaseline = fileURL.flatMap { GitRepository.baseline(for: $0) }
        updateGitChangeMarkers()
    }

    private func updateGitChangeMarkers() {
        guard let editor else { return }
        editor.gitChangeSet = gitBaseline.map {
            GitLineChanges.changes(baseline: $0, current: editor.rawSource)
        } ?? GitLineChangeSet()
        navigationSidebar?.updateCurrentBufferGitState(
            differsFromHEAD: !editor.gitChangeSet.lines.isEmpty
                || !editor.gitChangeSet.deletionBoundaries.isEmpty
        )
    }

    private func checkForExternalFileChange() {
        guard let url = fileURL, editor != nil else { return }
        // An own coordinated write can notify NSFilePresenter while it is in
        // flight. Its completion re-checks the persisted save snapshot, so
        // reading the path here would only observe a partial or stale phase.
        guard activeOwnFileWrites == 0 else { return }

        do {
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: AppCopy.text(
                        "Could not read externally modified file as UTF-8",
                        "无法以 UTF-8 编码读取外部修改后的文件")]
                )
            }
            // NSFilePresenter notifications are allowed to arrive after the
            // save completion. Voice/IME input may already have advanced the
            // live buffer by then; compare with what FloralMD wrote, not with
            // the newer editor text, before calling it an external change.
            if mostRecentOwnWriteSnapshot?.matches(fileURL: url, diskContent: content) == true {
                Log.info("Ignored delayed file-change notification for FloralMD's own save",
                         category: .io)
                return
            }
            // Once a different disk state is observed, an external tool may
            // later write bytes equal to an older FloralMD snapshot. That later
            // write is a real new event and must not inherit the old exemption.
            mostRecentOwnWriteSnapshot = nil
            pendingExternalContent = content
            resolvePendingExternalChange()
        } catch {
            Log.error("External file refresh failed: \(error.localizedDescription)", category: .io)
        }
    }

    private func restartExternalFileMonitor() {
        externalFileMonitor?.stop()
        externalFileMonitor = nil
        guard activeOwnFileWrites == 0 else { return }
        guard let url = fileURL, editor != nil else { return }

        let monitor = ExternalFileMonitor(url: url) { [weak self] in
            self?.checkForExternalFileChange()
        }
        externalFileMonitor = monitor
        monitor.start()
    }

    private func beginOwnFileWrite() {
        activeOwnFileWrites += 1
        guard activeOwnFileWrites == 1 else { return }
        // A vnode source cannot identify the writing process. Pause it around
        // NSDocument's own (usually atomic) replacement so FloralMD does not
        // report its autosave snapshot as an external modification while the
        // user has already continued typing.
        externalFileMonitor?.stop()
        externalFileMonitor = nil
    }

    private func finishOwnFileWrite(checkForExternalChange: Bool) {
        guard activeOwnFileWrites > 0 else { return }
        shouldCheckExternalFileAfterOwnWrites =
            shouldCheckExternalFileAfterOwnWrites || checkForExternalChange
        activeOwnFileWrites -= 1
        guard activeOwnFileWrites == 0 else { return }

        restartExternalFileMonitor()
        if shouldCheckExternalFileAfterOwnWrites {
            shouldCheckExternalFileAfterOwnWrites = false
            checkForExternalFileChange()
        }
    }

    private func resolvePendingExternalChange() {
        guard let content = pendingExternalContent, let editor else { return }

        // Replacing storage during marked text can strand the input context.
        // editorDidSynchronizeText retries this after composition commits.
        guard !editor.hasMarkedText() else { return }

        let normalized = LineEnding.normalize(content)
        let diskEnding = LineEnding.isInconsistent(in: content)
            ? LineEnding.lf : LineEnding.detect(in: content)
        let matchesEditor = normalized == editor.rawSource
            && diskEnding == editor.originalLineEnding

        if matchesEditor {
            pendingExternalContent = nil
            // Another process may have written exactly what FloralMD currently
            // holds; it is now a valid saved baseline.
            if isDocumentEdited { updateChangeCount(.changeCleared) }
            return
        }

        guard isDocumentEdited else {
            applyExternalContent(content)
            return
        }

        switch AppSettings.conflictResolution {
        case .keepCurrent:
            pendingExternalContent = nil
        case .updateToModified:
            applyExternalContent(content)
        case .ask:
            presentExternalChangeConflict()
        }
    }

    private func applyExternalContent(_ content: String) {
        guard editor.reloadContent(content) else {
            pendingExternalContent = content
            return
        }

        pendingExternalContent = nil
        updateChangeCount(.changeCleared)
        warnIfInconsistentLineEndings(in: content)
        refreshReadView()
        updateStatusBar()
        updateOutline()
        refreshGitChangeMarkers()
        refreshNavigationSidebar()
        minimapView?.refresh()
        Log.info("Reloaded document after external file change", category: .io)
    }

    private func presentExternalChangeConflict() {
        guard !isPresentingExternalConflict,
              let window = windowControllers.first?.window,
              let url = fileURL else { return }

        isPresentingExternalConflict = true
        let alert = NSAlert()
        alert.messageText = AppCopy.text("File Changed on Disk", "文件已在磁盘上更改")
        alert.informativeText = AppCopy.text(
            "\(url.lastPathComponent) was modified by another application while FloralMD has unsaved changes.",
            "FloralMD 中尚有未保存的修改，但 \(url.lastPathComponent) 已被其他应用修改。")
        alert.addButton(withTitle: AppCopy.text("Keep My Changes", "保留我的修改"))
        alert.addButton(withTitle: AppCopy.text("Reload from Disk", "从磁盘重新载入"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingExternalConflict = false
            if response == .alertSecondButtonReturn,
               let latestContent = self.pendingExternalContent {
                self.applyExternalContent(latestContent)
            } else {
                self.pendingExternalContent = nil
            }
        }
    }

    /// Warn (once, suppressibly) when an opened file mixed line-ending styles.
    /// The buffer has already been normalized to a single style for editing.
    private func warnIfInconsistentLineEndings(in content: String) {
        guard LineEnding.isInconsistent(in: content),
              !AppSettings.suppressInconsistentLineEndingWarning,
              let window = windowControllers.first?.window else { return }

        let alert = NSAlert()
        alert.messageText = AppCopy.text("Inconsistent Line Endings", "换行符不一致")
        alert.informativeText = AppCopy.text(
            "This document mixes different line endings. It will be saved using \(editor?.originalLineEnding.displayName ?? "LF") throughout.",
            "此文档混用了不同的换行符。保存时将统一使用 \(editor?.originalLineEnding.displayName ?? "LF")。")
        alert.addButton(withTitle: AppCopy.text("OK", "好"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = AppCopy.text("Do not warn about inconsistent line endings", "不再提示换行符不一致")
        alert.beginSheetModal(for: window) { _ in
            if alert.suppressionButton?.state == .on {
                AppSettings.suppressInconsistentLineEndingWarning = true
            }
        }
    }

    /// Cross-file link following: scroll this document's editor to a heading
    /// once it's on screen (the content has already loaded in showWindows).
    func navigateToHeading(_ heading: String) {
        editor?.scrollToHeading(heading)
    }

    // MARK: - Rename & Move (manual — NSDocument's built-in versions
    //         are disabled without Info.plist / .app bundle)

    override func rename(_ sender: Any?) {
        guard let url = fileURL, let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.prompt = AppCopy.text("Rename", "重命名")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let newURL = panel.url else { return }
            do {
                guard newURL.deletingLastPathComponent().standardizedFileURL
                    == url.deletingLastPathComponent().standardizedFileURL else {
                    throw DocumentFileRenameError.directoryChanged
                }
                let request = try DocumentFileRenameRequest(
                    sourceURL: url,
                    proposedFullName: newURL.lastPathComponent
                )
                self.performFileRename(request) { result in
                    if case .failure(let error) = result {
                        let alert = NSAlert(error: error)
                        alert.beginSheetModal(for: window)
                    }
                }
            } catch {
                let alert = NSAlert(error: localizedDocumentRenameError(error))
                alert.beginSheetModal(for: window)
            }
        }
    }

    func performFileRename(
        _ request: DocumentFileRenameRequest,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        beginOwnFileWrite()
        OpenDocumentFileRenameCoordinator.rename(request, document: self) { [weak self] result in
            guard let self else { return }
            self.mostRecentOwnWriteSnapshot = nil
            self.finishOwnFileWrite(checkForExternalChange: false)
            switch result {
            case .success(let destination):
                NSDocumentController.shared.noteNewRecentDocumentURL(destination)
                self.refreshGitChangeMarkers()
                NotificationCenter.default.post(
                    name: DocumentController.documentsDidChange,
                    object: NSDocumentController.shared
                )
                completion(.success(destination))
            case .failure(let error):
                self.refreshNavigationSidebar()
                completion(.failure(localizedDocumentRenameError(error)))
            }
        }
    }

    var renameFileURL: URL? { fileURL }

    func moveFileForRename(to url: URL,
                           completionHandler: @escaping @MainActor (Error?) -> Void) {
        move(to: url) { error in
            MainActor.assumeIsolated {
                completionHandler(error)
            }
        }
    }

    override func move(_ sender: Any?) {
        guard let url = fileURL, let window = windowControllers.first?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = AppCopy.text("Move", "移动")
        panel.message = AppCopy.text(
            "Choose a new location for \"\(url.lastPathComponent)\"",
            "为“\(url.lastPathComponent)”选择新位置")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destDir = panel.url else { return }
            let newURL = destDir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: newURL)
                self.fileURL = newURL
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - View Mode (edit / reading / source)

    private func icon(for mode: EditorTextView.ViewMode) -> NSImage? {
        let name: String
        switch mode {
        // Source is a raw-text view of the same editing mode as Edit, so it
        // shares the pencil icon rather than getting a distinct glyph.
        case .edit, .source: name = "pencil"
        case .reading:       name = "book"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: label(for: mode))
    }

    private func label(for mode: EditorTextView.ViewMode) -> String {
        switch mode {
        case .edit:    return AppCopy.text("Edit", "编辑")
        case .reading: return AppCopy.text("Read", "阅读")
        case .source:  return AppCopy.text("Source", "源码")
        }
    }

    /// Shows the active mode's icon on the button and keeps the tooltip in sync.
    private func refreshViewModeButton() {
        guard let editor else { return }
        viewModeButton?.image = icon(for: editor.viewMode)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let description = AppCopy.text("View mode: ", "视图模式：") + label(for: editor.viewMode)
        viewModeButton?.toolTip = withShortcut(description, commandID: "view.toggleMode")
        viewModeButton?.setAccessibilityLabel(description)
        viewModeButton?.setAccessibilityHelp(viewModeButton?.toolTip)
    }

    private func setViewMode(_ mode: EditorTextView.ViewMode) {
        editor.viewMode = mode
        applyViewMode(mode)
        refreshViewModeButton()
    }

    /// Swaps the on-screen view for the mode: Read mode shows the rendered-HTML
    /// `ReadModeWebView`; Edit and Source stay on the editor's scroll view.
    private func applyViewMode(_ mode: EditorTextView.ViewMode) {
        guard let containerView else { return }
        if mode == .reading {
            let read = readView ?? {
                let v = ReadModeWebView()
                v.usesTransparentBackground = usesTranslucentPinnedWindowBackground
                v.frame = NSRect(x: scrollView.frame.minX, y: scrollView.frame.minY,
                                 width: scrollView.frame.width + minimapView.frame.width,
                                 height: scrollView.frame.height)
                v.autoresizingMask = [.width, .height]
                // Below the floating status bar so counts stay visible.
                containerView.addSubview(v, positioned: .below, relativeTo: statusBar)
                // Route internal navigation through the editor's link resolver
                // (which resolves against this document's directory and opens via
                // NSDocumentController) instead of navigating the webview.
                v.onOpenWikiLink = { [weak self] in self?.editor.followWikiLink($0) }
                v.onOpenInternalLink = { [weak self] in self?.editor.followLinkDestination($0) }
                readView = v
                return v
            }()
            read.render(markdown: editor.rawSource,
                        theme: editor.theme,
                        callouts: mergedCallouts,
                        baseURL: documentDirectory,
                        options: renderOptions)
            read.isHidden = false
            minimapView?.isHidden = true
            scrollView.isHidden = true
            editor.window?.makeFirstResponder(read)
        } else {
            readView?.isHidden = true
            scrollView.isHidden = false
            minimapView?.isHidden = !AppSettings.showMinimap
            editor.window?.makeFirstResponder(editor)
        }
    }

    /// Re-renders an open Read view from the editor's current source + theme.
    /// No-op unless Read mode is the active, visible view — so settings/edit
    /// broadcasts stay cheap when the user is in Edit or Source mode.
    func refreshReadView() {
        guard let read = readView, !read.isHidden, editor?.viewMode == .reading else { return }
        read.render(markdown: editor.rawSource,
                    theme: editor.theme,
                    callouts: mergedCallouts,
                    baseURL: documentDirectory,
                    options: renderOptions)
    }

    /// The opened file's directory, used to resolve relative image paths for
    /// inlining (nil for an unsaved document).
    private var documentDirectory: URL? {
        fileURL?.deletingLastPathComponent()
    }

    /// Built-in callout styles merged with the editor's user overrides, so Read
    /// mode and the PDF match exactly what the editor draws.
    private var mergedCallouts: [String: CalloutStyle] {
        var m = Callout.defaultStyles
        for (k, v) in editor.calloutStyleOverrides { m[k] = v }
        return m
    }

    /// Read-mode/export render options derived from user settings. Reuses the
    /// editor's own `maxContentWidthPoints` (already the cm setting converted via
    /// the window's screen PPI) so Read mode's column matches Edit mode's.
    private var renderOptions: ReadRenderOptions {
        ReadRenderOptions(preserveBlankLines: AppSettings.renderBlankLinesAsBreaks,
                         allowRemoteImages: !AppSettings.blockExternalImages,
                         maxContentWidthPoints: Double(editor.maxContentWidthPoints))
    }

    // MARK: - Export / Print

    @objc func exportToPDF(_ sender: Any?) {
        let name = (displayName as NSString).deletingPathExtension
        MarkdownPrinter.exportPDF(markdown: editor.rawSource,
                                  theme: editor.theme,
                                  callouts: mergedCallouts,
                                  baseURL: documentDirectory,
                                  options: renderOptions,
                                  suggestedName: name.isEmpty ? AppCopy.text("Untitled", "未命名") : name,
                                  window: windowControllers.first?.window)
    }

    @objc override func printDocument(_ sender: Any?) {
        MarkdownPrinter.print(markdown: editor.rawSource,
                              theme: editor.theme,
                              callouts: mergedCallouts,
                              baseURL: documentDirectory,
                              options: renderOptions,
                              window: windowControllers.first?.window)
    }

    /// The editing-side view: Source when source mode is on, otherwise Edit.
    /// Read is the other half of the toggle.
    private var editingMode: EditorTextView.ViewMode {
        AppSettings.sourceMode ? .source : .edit
    }

    @objc private func selectEditMode(_ sender: Any?)    { setViewMode(editingMode) }
    @objc private func selectReadingMode(_ sender: Any?) { setViewMode(.reading) }

    /// The toolbar button's context-menu entry shares the same global setter as
    /// the View menu, its shortcut, and the Editor settings pane.
    @objc func toggleSourceMode(_ sender: Any?) {
        EditorPreferenceCoordinator.setSourceMode(!AppSettings.sourceMode)
    }

    /// Toggle the editing view ↔ Read (the View-menu ⌘E item and the toolbar
    /// button). With source mode on the editing view is Source, so this flips
    /// Source ↔ Read; otherwise Edit ↔ Read.
    @objc func toggleViewMode(_ sender: Any?) {
        setViewMode(editor.viewMode == .reading ? editingMode : .reading)
    }

    /// One mode menu item: icon + title, checked when `on`.
    private func menuItem(_ title: String, _ image: NSImage?,
                          _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = image
        item.state = on ? .on : .off
        return item
    }

    /// The right-click menu: Edit / Read selection, a divider, then the
    /// "Show source in editor" checkbox. Built fresh each time so state stays current.
    fileprivate func viewModeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false   // actions always fire on selection
        let inEditing = editor?.viewMode != .reading
        menu.addItem(menuItem(AppCopy.text("Edit", "编辑"), icon(for: .edit),
                              #selector(selectEditMode(_:)), on: inEditing))
        menu.addItem(menuItem(AppCopy.text("Read", "阅读"), icon(for: .reading),
                              #selector(selectReadingMode(_:)), on: !inEditing))
        menu.addItem(.separator())
        menu.addItem(menuItem(AppCopy.text("Show source in editor", "在编辑器中显示源码"), nil,
                              #selector(toggleSourceMode(_:)), on: AppSettings.sourceMode))
        return menu
    }

    // MARK: - Writing

    override func save(to url: URL, ofType typeName: String,
                       for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let coordinatesDestinationWrite = fileURL == nil
            || fileURL?.standardizedFileURL == url.standardizedFileURL
            || saveOperation == .saveAsOperation
        let sourceAtSaveStart = editor?.rawSource
        let lineEndingAtSaveStart = editor?.originalLineEnding
        if coordinatesDestinationWrite {
            beginOwnFileWrite()
        }
        setSavePresentation(.saving)
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }

            let savedCurrentFile = self.fileURL?.standardizedFileURL == url.standardizedFileURL
            let persistedContentMatchesSaveSnapshot = if error == nil,
                                                         let sourceAtSaveStart,
                                                         let lineEndingAtSaveStart {
                self.contentsOnDisk(at: url,
                                    match: sourceAtSaveStart,
                                    lineEnding: lineEndingAtSaveStart)
            } else {
                false
            }
            if persistedContentMatchesSaveSnapshot,
               let sourceAtSaveStart,
               let lineEndingAtSaveStart {
                self.mostRecentOwnWriteSnapshot = DocumentOwnWriteSnapshot(
                    fileURL: url,
                    rawSource: sourceAtSaveStart,
                    lineEnding: lineEndingAtSaveStart
                )
            }
            if coordinatesDestinationWrite {
                self.finishOwnFileWrite(
                    checkForExternalChange: error == nil
                        && !persistedContentMatchesSaveSnapshot
                )
            }
            let persistedContentMatchesEditor = error == nil && self.contentsOnDiskMatchEditor(at: url)

            if error != nil {
                self.setSavePresentation(.failed)
            } else if savedCurrentFile && persistedContentMatchesEditor && !self.isDocumentEdited {
                self.setSavePresentation(.saved)
            } else {
                self.setSavePresentation(self.isDocumentEdited ? .unsaved : self.cleanSavePresentation)
            }
            completionHandler(error)
        }
    }

    private func reconcileDirtyStateWithDisk(reason: String) {
        let matchesDisk = fileURL.map(contentsOnDiskMatchEditor(at:)) ?? false
        guard fileURL != nil,
              DocumentSavePolicy.shouldClearDirtyStateAfterSave(
                saveSucceeded: true,
                savedCurrentFile: true,
                persistedContentMatchesEditor: matchesDisk
              ) else { return }
        if isDocumentEdited {
            updateChangeCount(.changeCleared)
        }
        // An autosave can clear NSDocument's change count without relaying the
        // clean state to its windows, leaving AppKit's "Edited" subtitle next
        // to FloralMD's verified "Saved" status. The disk match above is the
        // safety gate for synchronizing both state owners.
        windowControllers.forEach { $0.setDocumentEdited(false) }
        setSavePresentation(.saved)
        Log.info("Cleared stale edited state after verified disk match (\(reason))",
                 category: .io)
    }

    private func contentsOnDiskMatchEditor(at url: URL) -> Bool {
        guard let editor else { return false }
        return contentsOnDisk(at: url,
                              match: editor.rawSource,
                              lineEnding: editor.originalLineEnding)
    }

    private func contentsOnDisk(at url: URL,
                                match rawSource: String,
                                lineEnding: LineEnding) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return false }
        let diskEnding = LineEnding.isInconsistent(in: content)
            ? LineEnding.lf : LineEnding.detect(in: content)
        return LineEnding.normalize(content) == rawSource
            && diskEnding == lineEnding
    }

    override func data(ofType typeName: String) throws -> Data {
        // The buffer is always LF; restore the file's original line ending on
        // write so opening, then saving, doesn't silently rewrite every line.
        let normalized = editor?.rawSource ?? ""
        let ending = editor?.originalLineEnding ?? .lf
        let text = ending == .lf
            ? normalized
            : normalized.replacingOccurrences(of: "\n", with: ending.string)
        guard let data = text.data(using: .utf8) else {
            Log.error("Save failed: could not encode \(text.count) chars as UTF-8", category: .io)
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: AppCopy.text("Could not encode text as UTF-8", "无法将文本编码为 UTF-8")])
        }
        Log.info("Saving \(data.count) bytes (\(ending.displayName))", category: .io)
        return data
    }
}

// MARK: - Toolbar (view-mode toggle)

extension Document: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.viewModeItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, Self.viewModeItemID]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.viewModeItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = AppCopy.text("View Mode", "视图模式")
        item.visibilityPriority = .high

        // Left-click toggles the editing view ↔ Read. The right-click mode menu
        // is handled upstream in DocumentWindow.sendEvent — every view-level
        // approach (the view's `menu`, rightMouseDown, a gesture recognizer)
        // loses the secondary click to the toolbar's "Customize Toolbar…" menu.
        let button = NSButton(image: NSImage(), target: self,
                              action: #selector(toggleViewMode(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        viewModeButton = button
        item.view = button
        refreshViewModeButton()
        return item
    }
}

/// Paints the document surface behind pane frames with the same semantic color
/// as the editor. Collapsed sidebars expose this view, so it must follow live
/// appearance changes; pinned translucency disables the fill alongside the
/// editor instead of stacking another translucent layer over the window.
private final class DocumentContainerView: NSView {
    var drawsBackground = true {
        didSet {
            guard oldValue != drawsBackground else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = drawsBackground
            ? NSColor.textBackgroundColor.cgColor
            : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Mirrors NSDocument's authoritative dirty state into the native window tab.
/// AppKit already forwards every dirty/clean transition through this method,
/// including successful manual saves and autosaves, so the tab needs no second
/// source of truth.
private final class DocumentWindowController: NSWindowController {
    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        (document as? Document)?.documentEditedStateDidChange(dirtyFlag)
        refreshTabUnsavedIndicator(dirty: dirtyFlag)
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        refreshTabUnsavedIndicator()
    }

    func refreshTabUnsavedIndicator() {
        refreshTabUnsavedIndicator(dirty: document?.isDocumentEdited == true)
    }

    private func refreshTabUnsavedIndicator(dirty: Bool) {
        guard let window else { return }
        window.tab.attributedTitle = nil
        window.tab.title = dirty ? "\(window.title)  ●" : window.title
    }
}

/// Document window that intercepts a secondary (right / control) click on the
/// view-mode toolbar button and shows the mode menu itself. `sendEvent` is the
/// single funnel all window events pass through *before* the toolbar/titlebar
/// can turn the click into its own "Customize Toolbar…" context menu, so this is
/// the one place the interception reliably wins.
final class DocumentWindow: NSWindow {
    weak var viewModeButton: NSView?
    var makeViewModeMenu: (() -> NSMenu)?
    var isAlwaysOnTop = false {
        didSet { applyPreferredLevel() }
    }
    private var isAlwaysOnTopSuspended = false

    func suspendAlwaysOnTopForFullScreen() {
        isAlwaysOnTopSuspended = true
        applyPreferredLevel()
    }

    func resumeAlwaysOnTopAfterFullScreen() {
        isAlwaysOnTopSuspended = false
        applyPreferredLevel()
    }

    private func applyPreferredLevel() {
        level = isAlwaysOnTop && !isAlwaysOnTopSuspended ? .floating : .normal
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
        case .leftMouseDown:  return event.modifierFlags.contains(.control)
        default:              return false
        }
    }
}

// Modified from Edmund by Yingkai Sun for FloralMD.
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
    private var outlineFloatingButton: OutlineFloatingButton!
    private var navigationSidebarButton: NSButton?
    private var windowPinningButton: NSButton?
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
    private var lastReadAnchorOffset: Int?
    private var pendingReadEntryRestore: (line: Int, fraction: Double)?
    private var gitBaseline: GitFileBaseline?
    private var usesTranslucentPinnedWindowBackground = false
    private var allSpacesPinnedPanelController: AllSpacesPinnedPanelController?

    /// Content loaded from disk before the editor window exists.
    /// `nonisolated(unsafe)` because `read(from:ofType:)` may be called
    /// off the main actor, but the value is only consumed on main via `showWindows`.
    nonisolated(unsafe) var pendingContent: String?

    /// Latest coordinated disk contents waiting for IME composition or an
    /// already-visible conflict sheet to finish.
    private var pendingExternalContent: String?
    private var isPresentingExternalConflict = false
    private var externalFileMonitor: ExternalFileMonitor?
    private var isPerformingFileTrash = false
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
        editor?.breakUndoCoalescingAfterSave()
        reconcileDirtyStateWithDisk(reason: "save-token")
    }

    override func canClose(withDelegate delegate: Any,
                           shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        editor?.commitMarkedTextForDocumentReview()
        reconcileUntitledContentState()
        if isDiscardableBlankUntitled,
           finishCanClose(withDelegate: delegate,
                          shouldClose: shouldCloseSelector,
                          contextInfo: contextInfo) {
            return
        }
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
        prepareForUnsavedDocumentReview()
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

    /// Selects an existing image and inserts an ordinary Markdown reference.
    /// This command never copies or takes ownership of the selected file.
    @objc func insertImageReference(_ sender: Any?) {
        guard editor?.viewMode != .reading,
              let window = windowControllers.first?.window else { NSSound.beep(); return }

        if AppSettings.imagePathStyle == .relative, fileURL == nil {
            presentSaveDocumentBeforeImageAlert(in: window)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.prompt = AppCopy.text("Insert", "插入")
        panel.message = AppCopy.text(
            "Choose an image to reference from this Markdown file.",
            "选择要在当前 Markdown 文件中引用的图片。"
        )
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let imageURL = panel.url,
                  let destination = ImageReference.destination(
                    documentURL: self.fileURL,
                    imageURL: imageURL,
                    style: AppSettings.imagePathStyle.referenceStyle
                  ) else { return }
            let alt = imageURL.deletingPathExtension().lastPathComponent
            self.editor.insertImageReference(destination: destination, defaultAltText: alt)
        }
    }

    /// Intercepts only clipboard payloads that can become a PNG. Ordinary text
    /// and Markdown paste stay on NSTextView's standard editing path.
    private func handleClipboardImagePaste() -> Bool {
        guard editor?.viewMode != .reading,
              let pngData = clipboardPNGData(from: .general) else { return false }
        guard let window = windowControllers.first?.window else { return true }
        guard fileURL != nil else {
            presentSaveDocumentBeforeImageAlert(in: window)
            return true
        }
        presentClipboardImageNameSheet(pngData: pngData, in: window)
        return true
    }

    private func clipboardPNGData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }

        let image: NSImage?
        if let tiff = pasteboard.data(forType: .tiff) {
            image = NSImage(data: tiff)
        } else {
            image = NSImage(pasteboard: pasteboard)
        }
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func presentClipboardImageNameSheet(pngData: Data, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("Name pasted image", "命名粘贴的图片")
        alert.informativeText = AppCopy.text(
            "The date and time prefix is editable. The image will be saved as PNG.",
            "日期和时间前缀可以编辑；图片将保存为 PNG。"
        )
        alert.addButton(withTitle: AppCopy.text("Save and Insert", "保存并插入"))
        alert.addButton(withTitle: AppCopy.text("Cancel", "取消"))

        let nameField = NSTextField(string: ImageReference.timestampPrefix(for: Date()))
        nameField.placeholderString = AppCopy.text("Image name", "图片名称")
        nameField.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        alert.beginSheetModal(for: window) { [weak self, weak nameField] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  let proposedName = nameField?.stringValue else { return }
            self.saveClipboardImage(pngData, proposedName: proposedName, in: window)
        }
        DispatchQueue.main.async { [weak nameField] in
            guard let nameField, let editor = nameField.currentEditor() else { return }
            editor.selectedRange = NSRange(location: nameField.stringValue.utf16.count, length: 0)
        }
    }

    private func saveClipboardImage(
        _ pngData: Data,
        proposedName: String,
        in window: NSWindow
    ) {
        guard let documentURL = fileURL else {
            presentSaveDocumentBeforeImageAlert(in: window)
            return
        }

        do {
            let folder = ImageReference.normalizedAssetFolder(AppSettings.imageAssetFolder)
            let directoryURL = documentURL.deletingLastPathComponent()
                .appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let baseName = ImageReference.sanitizedImageBaseName(proposedName)
            let imageURL = uniqueImageURL(in: directoryURL, baseName: baseName)
            try pngData.write(to: imageURL, options: .withoutOverwriting)

            guard let destination = ImageReference.destination(
                documentURL: documentURL,
                imageURL: imageURL,
                style: AppSettings.imagePathStyle.referenceStyle
            ) else { return }
            editor.insertImageReference(destination: destination, defaultAltText: baseName)
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    private func uniqueImageURL(in directoryURL: URL, baseName: String) -> URL {
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let candidate = directoryURL.appendingPathComponent(name).appendingPathExtension("png")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private func presentSaveDocumentBeforeImageAlert(in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("Save the document first", "请先保存文档")
        alert.informativeText = AppCopy.text(
            "FloralMD needs the document location before it can save or create a relative image reference.",
            "FloralMD 需要先确定文档位置，才能保存图片或创建相对图片引用。"
        )
        alert.addButton(withTitle: AppCopy.text("OK", "好"))
        alert.beginSheetModal(for: window)
    }

    // MARK: - Window Setup

    override func makeWindowControllers() {
        // Default content size for first launch. Any saved size is applied as a
        // full window frame at the end of setup (below), once the toolbar is in
        // place — so the frame round-trips exactly and doesn't drift by the
        // title bar + toolbar height each time.
        let windowWidth: CGFloat = 900
        let windowHeight: CGFloat = 620

        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.prepareForOwnFullScreen = { [weak self] in
            self?.dismissAllSpacesPinnedPanel(restoringDocumentWindow: true)
        }
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.applyPinningPresentation()
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
        editor.textContainerInset = NSSize(width: 44, height: 30)
        // Centered reading column (see EditorTextView+ContentWidth). Convert the
        // persisted cm value to points using the main screen PPI at window-creation
        // time; recomputed on resize (setFrameSize) and when the window moves to a
        // different display (windowDidChangeScreen).
        let initScreen = NSScreen.main
        editor.maxContentWidthPoints = initScreen?.cmToPoints(AppSettings.maxContentWidthCm) ?? 1000
        editor.updateContentInset()
        editor.allowRemoteImages = !AppSettings.blockExternalImages
        editor.typewriterModeEnabled = AppSettings.typewriterMode
        editor.markdownFeatures = AppSettings.markdownFeatures
        editor.codeBlockCopyStrings = readModeCopyStrings
        editor.linkNavigationHint = AppCopy.text(
            "Hold Command and click to follow link",
            "按住 Command 点击跳转"
        )
        editor.document = self
        editor.imagePasteHandler = { [weak self] in
            self?.handleClipboardImagePaste() ?? false
        }

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
        window.titlebarSeparatorStyle = .none
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
        navigationSidebar.canMoveFileToTrash = { url in
            guard let controller = NSDocumentController.shared as? DocumentController else {
                return false
            }
            return controller.canMoveFileToTrash(at: url)
        }
        navigationSidebar.onMoveFileToTrash = { [weak self] url in
            guard let self,
                  let controller = NSDocumentController.shared as? DocumentController else { return }
            controller.moveFileToTrash(at: url, from: self)
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
        outlineSidebar.onCollapseRequest = { [weak self] in
            self?.toggleOutlineSidebar(nil)
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
        outlineFloatingButton = OutlineFloatingButton(frame: initialLayout.outlineControlFrame)
        // Adding or removing a native tab bar changes the content-view height
        // without resizing the window. Keep the button anchored to the canvas
        // top even when NSWindow.didResize is therefore not delivered.
        outlineFloatingButton.autoresizingMask = DocumentPaneLayout.outlineControlAutoresizingMask
        outlineFloatingButton.target = self
        outlineFloatingButton.action = #selector(toggleOutlineSidebar(_:))
        containerView.addSubview(outlineFloatingButton)
        let surfaceSeparator = DocumentSurfaceSeparatorView(
            frame: NSRect(x: 0, y: contentBounds.height - 1,
                          width: contentBounds.width, height: 1)
        )
        surfaceSeparator.autoresizingMask = [.width, .minYMargin]
        containerView.addSubview(surfaceSeparator)
        // This is a one-time window-session default. Later refreshes never
        // reapply it, so either sidebar stays open after the user expands it.
        outlineSidebar.setExpanded(sidebarSessionState.isOutlineExpanded, animated: false)
        navigationSidebar.setExpanded(sidebarSessionState.isNavigationExpanded, animated: false)

        (containerView as? DocumentContainerView)?.onAppearanceChange = { [weak self] in
            self?.refreshPinnedWindowPresentation()
        }
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
            self, selector: #selector(windowWillEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification, object: window
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
            outlineFloatingButton.animator().frame = layout.outlineControlFrame
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
        editor.codeBlockCopyStrings = readModeCopyStrings
        editor.linkNavigationHint = AppCopy.text(
            "Hold Command and click to follow link",
            "按住 Command 点击跳转"
        )
        refreshWindowTitle()
        refreshSavePresentation()
        refreshViewModeButton()
        updateStatusBar()
        if let item = windowControllers.first?.window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.viewModeItemID }) {
            item.label = AppCopy.text("View Mode", "视图模式")
            item.paletteLabel = item.label
        }
        refreshSidebarControlAppearance()
        refreshWindowPinningButtonAppearance()
        refreshReadView()
    }

    func refreshShortcutPresentation() {
        refreshSidebarControlAppearance()
        refreshViewModeButton()
    }

    /// Stable window-level controls beside the traffic lights toggle repository
    /// navigation and expose pinning. The document outline lives on the canvas.
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

        let navigationButton = makeButton(action: #selector(toggleNavigationSidebar(_:)))
        let pinningButton = makeButton(action: #selector(showWindowPinningMenu(_:)))
        let controls = NSStackView(views: [navigationButton, pinningButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 62, height: 30))
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 62),
            container.heightAnchor.constraint(equalToConstant: 30),
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
        navigationSidebarButton = navigationButton
        windowPinningButton = pinningButton
        refreshSidebarControlAppearance()
        refreshWindowPinningButtonAppearance()
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
        update(outlineFloatingButton, symbol: "list.bullet.indent", description: outlineDescription)
        outlineFloatingButton?.isHidden = sidebarSessionState.isOutlineExpanded
    }

    private func refreshWindowPinningButtonAppearance() {
        let description = switch windowPinningMode {
        case .none:
            AppCopy.text("Window Pinning: Off", "窗口置顶：关闭")
        case .currentSpace:
            AppCopy.text("Window Pinning: Current Space", "窗口置顶：当前 Space")
        case .allSpaces:
            AppCopy.text("Window Pinning: All Spaces", "窗口置顶：所有 Space")
        }
        windowPinningButton?.image = NSImage(
            systemSymbolName: windowPinningMode.statusSymbolName,
            accessibilityDescription: description
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        windowPinningButton?.toolTip = description
        windowPinningButton?.setAccessibilityLabel(description)
    }

    @objc private func showWindowPinningMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(pinningMenuItem(
            title: AppCopy.text("Off", "不置顶"),
            mode: .none,
            action: #selector(setNoWindowPinning(_:))
        ))
        menu.addItem(pinningMenuItem(
            title: AppCopy.text("Current Space", "仅当前 Space 置顶"),
            mode: .currentSpace,
            action: #selector(setCurrentSpaceWindowPinning(_:))
        ))
        menu.addItem(pinningMenuItem(
            title: AppCopy.text("All Spaces", "跨所有 Space 置顶"),
            mode: .allSpaces,
            action: #selector(setAllSpacesWindowPinning(_:))
        ))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
                   in: sender)
    }

    private func pinningMenuItem(title: String,
                                 mode: WindowPinningMode,
                                 action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = windowPinningMode == mode ? .on : .off
        return item
    }

    @objc private func setNoWindowPinning(_ sender: Any?) {
        setPinningMode(.none)
    }

    @objc private func setCurrentSpaceWindowPinning(_ sender: Any?) {
        setPinningMode(.currentSpace)
    }

    @objc private func setAllSpacesWindowPinning(_ sender: Any?) {
        setPinningMode(.allSpaces)
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
        guard let window = presentationWindow else { return }
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

    private var activeAllSpacesPinnedPanelController: AllSpacesPinnedPanelController? {
        guard allSpacesPinnedPanelController?.isPresented == true else { return nil }
        return allSpacesPinnedPanelController
    }

    private var presentationWindow: NSWindow? {
        activeAllSpacesPinnedPanelController?.panel ?? windowControllers.first?.window
    }

    var windowPinningMode: WindowPinningMode {
        (windowControllers.first?.window as? DocumentWindow)?.pinningMode ?? .none
    }

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        setPinningMode(windowPinningMode == .currentSpace ? .none : .currentSpace)
    }

    @objc func toggleAlwaysOnTopAcrossSpaces(_ sender: Any?) {
        setPinningMode(windowPinningMode == .allSpaces ? .none : .allSpaces)
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

    func setPinningMode(_ mode: WindowPinningMode) {
        guard let window = windowControllers.first?.window else { return }
        let groupedDocumentWindows = activeAllSpacesPinnedPanelController?.documentWindows
            ?? documentWindows(including: window)
        let selectedDocumentWindow = activeAllSpacesPinnedPanelController?.documentWindow
            ?? window.tabGroup?.selectedWindow as? DocumentWindow
            ?? groupedDocumentWindows.first(where: { $0.isKeyWindow })
            ?? window as? DocumentWindow
        let groupedDocuments = groupedDocumentWindows.compactMap { documentWindow -> Document? in
            documentWindow.windowController?.document as? Document
        }
        if mode != .allSpaces {
            for document in groupedDocuments {
                document.dismissAllSpacesPinnedPanel(restoringDocumentWindow: false)
            }
        }
        for documentWindow in groupedDocumentWindows {
            documentWindow.pinningMode = mode
        }
        if mode == .allSpaces {
            presentAllSpacesPinnedPanels(
                for: groupedDocuments,
                selectedDocumentWindow: selectedDocumentWindow
            )
        } else if let selectedDocumentWindow {
            selectedDocumentWindow.makeKeyAndOrderFront(nil)
        }
        for document in groupedDocuments {
            document.refreshWindowPinningButtonAppearance()
            document.refreshPinnedWindowPresentation()
        }
    }

    private func presentAllSpacesPinnedPanels(for documents: [Document],
                                              selectedDocumentWindow: DocumentWindow?) {
        let tabbingIdentifier = "floralmd.all-spaces.\(UUID().uuidString)"
        let groupedDocumentWindows = documents.compactMap {
            $0.windowControllers.first?.window as? DocumentWindow
        }
        for document in documents {
            if let cachedController = document.allSpacesPinnedPanelController,
               !cachedController.represents(documentWindows: groupedDocumentWindows) {
                document.discardAllSpacesPinnedPanelCache()
            }
        }
        for document in documents {
            guard let documentWindow = document.windowControllers.first?.window as? DocumentWindow else {
                continue
            }
            document.presentAllSpacesPinnedPanelIfNeeded(
                from: documentWindow,
                tabbingIdentifier: tabbingIdentifier,
                activate: false
            )
        }

        let controllers = documents.compactMap(\.allSpacesPinnedPanelController)
        if let firstPanel = controllers.first?.panel {
            for controller in controllers.dropFirst()
            where controller.panel.tabGroup !== firstPanel.tabGroup {
                firstPanel.addTabbedWindow(controller.panel, ordered: .above)
            }
        }
        let selectedController = controllers.first {
            $0.documentWindow === selectedDocumentWindow
        } ?? controllers.first
        selectedController?.activatePanel()
    }

    private func presentAllSpacesPinnedPanelIfNeeded(from window: NSWindow,
                                                     tabbingIdentifier: String? = nil,
                                                     activate: Bool = true) {
        if let controller = allSpacesPinnedPanelController {
            guard !controller.isPresented else { return }
            controller.present(
                in: self,
                tabbingIdentifier: tabbingIdentifier
                    ?? "floralmd.all-spaces.\(UUID().uuidString)",
                activate: activate
            )
            return
        }
        guard let documentWindow = window as? DocumentWindow,
              !documentWindow.styleMask.contains(.fullScreen),
              let contentView = documentWindow.contentView,
              let editor else {
            Log.info(
                "All-Spaces auxiliary panel deferred until the document exits full screen",
                category: .app
            )
            return
        }

        let controller = AllSpacesPinnedPanelController(
            documentWindow: documentWindow,
            contentView: contentView,
            editor: editor,
            titlebarAccessories: [sidebarControlsAccessory].compactMap { $0 },
            tabbingIdentifier: tabbingIdentifier
                ?? "floralmd.all-spaces.\(UUID().uuidString)"
        )
        allSpacesPinnedPanelController = controller
        controller.present(
            in: self,
            tabbingIdentifier: tabbingIdentifier
                ?? "floralmd.all-spaces.\(UUID().uuidString)",
            activate: activate
        )
    }

    private func dismissAllSpacesPinnedPanel(restoringDocumentWindow: Bool) {
        guard let controller = allSpacesPinnedPanelController else { return }
        controller.dismiss(restoringDocumentWindow: restoringDocumentWindow)
    }

    private func discardAllSpacesPinnedPanelCache() {
        guard let controller = allSpacesPinnedPanelController else { return }
        if controller.isPresented {
            controller.dismiss(restoringDocumentWindow: false)
        }
        controller.invalidateCache()
        allSpacesPinnedPanelController = nil
    }

    /// Adds one document to the visible auxiliary tab group without exposing
    /// the hidden ordinary hosts or rebuilding every existing panel.
    func activateDocumentIncrementallyInAllSpaces(_ target: Document) -> Bool {
        guard let sourceController = activeAllSpacesPinnedPanelController,
              let sourceWindow = windowControllers.first?.window as? DocumentWindow,
              let targetWindow = target.windowControllers.first?.window as? DocumentWindow else {
            return false
        }

        if sourceController.documentWindows.contains(where: { $0 === targetWindow }),
           let targetController = target.activeAllSpacesPinnedPanelController {
            targetController.activatePanel()
            return true
        }

        // A document already pinned in a different group must first restore
        // its ordinary host so the original presentation state is captured.
        if target.activeAllSpacesPinnedPanelController != nil {
            target.prepareForNativeTabMutation()
        }

        let originalAlpha = targetWindow.alphaValue
        let originalIgnoresMouseEvents = targetWindow.ignoresMouseEvents
        targetWindow.alphaValue = 0
        targetWindow.ignoresMouseEvents = true
        let groupedWindows = targetWindow.tabGroup?.windows ?? targetWindow.tabbedWindows ?? []
        if !groupedWindows.contains(sourceWindow) {
            sourceWindow.addTabbedWindow(targetWindow, ordered: .above)
        }
        targetWindow.pinningMode = .allSpaces

        let updatedDocumentWindows = documentWindows(including: sourceWindow)
        if let cachedController = target.allSpacesPinnedPanelController,
           !cachedController.represents(documentWindows: updatedDocumentWindows) {
            target.discardAllSpacesPinnedPanelCache()
        }
        let tabbingIdentifier = sourceController.panel.tabbingIdentifier
        target.presentAllSpacesPinnedPanelIfNeeded(
            from: targetWindow,
            tabbingIdentifier: tabbingIdentifier,
            activate: false
        )
        guard let targetController = target.activeAllSpacesPinnedPanelController else {
            targetWindow.alphaValue = originalAlpha
            targetWindow.ignoresMouseEvents = originalIgnoresMouseEvents
            return false
        }
        targetController.preserveDocumentWindowPresentationForDismissal(
            alpha: originalAlpha,
            ignoresMouseEvents: originalIgnoresMouseEvents
        )

        let groupedDocuments = updatedDocumentWindows.compactMap {
            $0.windowController?.document as? Document
        }
        for document in groupedDocuments {
            document.allSpacesPinnedPanelController?.updateDocumentWindows(updatedDocumentWindows)
            document.refreshWindowPinningButtonAppearance()
            document.refreshPinnedWindowPresentation()
        }
        DispatchQueue.main.async { [weak self, weak target,
                                    weak sourceController, weak targetController] in
            guard let self, let target, let sourceController, let targetController,
                  self.activeAllSpacesPinnedPanelController === sourceController,
                  target.activeAllSpacesPinnedPanelController === targetController else {
                return
            }
            if targetController.panel.tabGroup !== sourceController.panel.tabGroup {
                sourceController.panel.addTabbedWindow(targetController.panel, ordered: .above)
            }
            targetController.activatePanel()
            target.finishHiddenWindowPresentationSetup()
        }
        return true
    }

    func activateAllSpacesPinnedPanelIfPresented() -> Bool {
        guard let controller = activeAllSpacesPinnedPanelController else { return false }
        controller.activatePanel()
        return true
    }

    /// Native tab mutation requires the ordinary document windows to be back
    /// in their AppKit tab group before a different document becomes active.
    func prepareForNativeTabMutation() {
        guard let controller = activeAllSpacesPinnedPanelController else { return }
        let groupedDocuments = controller.documentWindows
            .compactMap { $0.windowController?.document as? Document }
        for document in groupedDocuments {
            document.dismissAllSpacesPinnedPanel(restoringDocumentWindow: false)
            document.discardAllSpacesPinnedPanelCache()
        }
    }

    /// A newly opened ordinary tab inherits only its own inexpensive window
    /// presentation. Calling `setPinningMode` after tabbing would refresh every
    /// document in the group even when the inherited mode is `.none`.
    func applyInheritedOrdinaryPinningMode(_ mode: WindowPinningMode) {
        guard mode != .allSpaces,
              let window = windowControllers.first?.window as? DocumentWindow else { return }
        window.pinningMode = mode
        refreshWindowPinningButtonAppearance()
        refreshPinnedWindowPresentation()
    }

    /// Builds and loads a document without ordering its ordinary host window.
    /// `NSDocumentController(display: false)` leaves `pendingContent` untouched
    /// because `showWindows()` is not called; moving that empty view into an
    /// auxiliary panel would expose a blank first frame.
    func prepareForHiddenWindowPresentation() {
        if windowControllers.isEmpty {
            makeWindowControllers()
        }
        loadPendingWindowContent()
        updateStatusBar()
        updateOutline()
    }

    func finishHiddenWindowPresentationSetup() {
        refreshGitChangeMarkers()
        refreshNavigationSidebar()
        restartExternalFileMonitor()
    }

    func requestOwnFullScreen(_ sender: Any?) {
        guard let window = windowControllers.first?.window as? DocumentWindow else { return }
        let groupedDocuments = (activeAllSpacesPinnedPanelController?.documentWindows
            ?? documentWindows(including: window)).compactMap {
                $0.windowController?.document as? Document
            }
        for document in groupedDocuments {
            document.dismissAllSpacesPinnedPanel(restoringDocumentWindow: false)
        }
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(sender)
    }

    func activateAsQuickCapture() {
        isQuickCapture = true
        if windowControllers.isEmpty {
            makeWindowControllers()
            showWindows()
        }
        setPinningMode(PinnedWindowPresentationPolicy.quickCaptureActivationMode(
            currentMode: windowPinningMode
        ))
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
        for tab in documentWindows(including: window) {
            tab.pinningMode = window.pinningMode
        }
        refreshWindowPinningButtonAppearance()
        refreshPinnedWindowPresentation()
    }

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        setPinningSuspendedForFullScreen(true, window: notification.object as? DocumentWindow)
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        refreshPinnedWindowPresentation()
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        setPinningSuspendedForFullScreen(false, window: notification.object as? DocumentWindow)
        if windowPinningMode == .allSpaces,
           let window = windowControllers.first?.window {
            let groupedDocuments = documentWindows(including: window).compactMap {
                $0.windowController?.document as? Document
            }
            presentAllSpacesPinnedPanels(
                for: groupedDocuments,
                selectedDocumentWindow: window as? DocumentWindow
            )
        }
        refreshPinnedWindowPresentation()
    }

    fileprivate func windowDidFailToEnterFullScreen(_ window: DocumentWindow) {
        setPinningSuspendedForFullScreen(false, window: window)
        if windowPinningMode == .allSpaces {
            let groupedDocuments = documentWindows(including: window).compactMap {
                $0.windowController?.document as? Document
            }
            presentAllSpacesPinnedPanels(
                for: groupedDocuments,
                selectedDocumentWindow: window
            )
        }
        refreshPinnedWindowPresentation()
    }

    private func setPinningSuspendedForFullScreen(_ suspended: Bool,
                                                  window: DocumentWindow?) {
        guard let window else { return }
        for tab in documentWindows(including: window) {
            if suspended {
                tab.suspendPinningForOwnFullScreen()
            } else {
                tab.resumePinningAfterOwnFullScreen()
            }
        }
    }

    private func documentWindows(including window: NSWindow) -> [DocumentWindow] {
        let windows = window.tabGroup?.windows ?? window.tabbedWindows ?? [window]
        return windows.compactMap { $0 as? DocumentWindow }
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        refreshPinnedWindowPresentation()
    }

    /// The window's alpha stays at 1 for all foreground content; only the content
    /// backgrounds stop drawing while the document window is pinned. This
    /// deliberately avoids `NSWindow.alphaValue`, which
    /// would also fade text, the caret, controls, images, and fragment overlays.
    private func refreshPinnedWindowPresentation() {
        guard let documentWindow = windowControllers.first?.window as? DocumentWindow,
              let window = presentationWindow else { return }
        let workspace = NSWorkspace.shared
        let opacity = PinnedWindowPresentationPolicy.backgroundOpacity(
            mode: documentWindow.pinningMode,
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
        reconcileUntitledContentState()
        handleUntitledSaveInputChange()
    }

    /// Normalize the editor before either the single-window or application-wide
    /// NSDocument review. This is intentionally synchronous: AppKit may have
    /// cached that a review is needed before calling the controller override.
    func prepareForUnsavedDocumentReview() {
        editor?.commitMarkedTextForDocumentReview()
        reconcileUntitledContentState()
    }

    private var isDiscardableBlankUntitled: Bool {
        guard let editor else { return false }
        return UntitledDocumentContentPolicy.isDiscardableBlankUntitled(
            hasFileURL: fileURL != nil,
            rawSource: editor.rawSource,
            hasMarkedText: editor.hasMarkedText()
        )
    }

    /// Untitled buffers use semantic content, not historical edit-event count,
    /// as their saved baseline. Clearing whitespace makes the draft disposable;
    /// Undo or continued typing that restores real content makes it dirty again.
    private func reconcileUntitledContentState() {
        guard let editor else { return }
        switch UntitledDocumentContentPolicy.dirtyStateAction(
            hasFileURL: fileURL != nil,
            rawSource: editor.rawSource,
            hasMarkedText: editor.hasMarkedText(),
            isDocumentEdited: isDocumentEdited
        ) {
        case .markEdited:
            updateChangeCount(.changeDone)
        case .clearEdited:
            updateChangeCount(.changeCleared)
        case .none:
            break
        }
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
        loadPendingWindowContent()
        finishHiddenWindowPresentationSetup()
        updateStatusBar()
        updateOutline()
    }

    private func loadPendingWindowContent() {
        if let content = pendingContent {
            editor?.loadContent(content)
            pendingContent = nil
            warnIfInconsistentLineEndings(in: content)
        }
    }

    override func close() {
        discardAllSpacesPinnedPanelCache()
        super.close()
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
        guard !isPerformingFileTrash else { return }
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
        guard !isPerformingFileTrash else { return }
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

    var canBeginFileTrashOperation: Bool {
        !isPerformingFileTrash
            && !isPresentingExternalConflict
            && pendingExternalContent == nil
    }

    /// Pauses the path-bound vnode monitor while NSWorkspace moves the file.
    /// NSDocument remains open until the recycle completion succeeds, so a
    /// permission failure leaves the tab and its in-memory buffer intact.
    @discardableResult
    func beginFileTrashOperation() -> Bool {
        guard canBeginFileTrashOperation else { return false }
        isPerformingFileTrash = true
        externalFileMonitor?.stop()
        externalFileMonitor = nil
        return true
    }

    func finishFileTrashOperation(succeeded: Bool) {
        guard isPerformingFileTrash else { return }
        if succeeded {
            // Keep monitoring suppressed until close() tears down this
            // document; the original path no longer exists.
            return
        }
        isPerformingFileTrash = false
        restartExternalFileMonitor()
    }

    func presentFileOperationError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let presentationWindow {
            alert.beginSheetModal(for: presentationWindow)
        } else {
            alert.runModal()
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
        editor?.scrollToWikiAnchor(heading)
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
        // Capture before the mode setter recomposes far blocks back to lazy
        // height estimates; afterward the geometry no longer matches the view
        // the user was actually looking at.
        if mode == .reading { captureReadEntryAnchor() }
        editor.viewMode = mode
        applyViewMode(mode)
        refreshViewModeButton()
    }

    private func captureReadEntryAnchor() {
        pendingReadEntryRestore = nil
        guard !scrollView.isHidden,
              let offset = editor.topmostVisibleCharacterOffset() else { return }
        let visibleLine = editor.line(forOffset: offset)
        let spans = ReadModeAnchors.topLevelBlockSpans(for: editor.rawSource)
        guard !spans.isEmpty else { return }
        let span = spans.last(where: { $0.startLine <= visibleLine }) ?? spans[0]
        let lineCount = Double(span.endLine - span.startLine + 1)
        let fraction = min(1, Double(visibleLine - span.startLine) / max(1, lineCount))
        pendingReadEntryRestore = (line: span.startLine, fraction: fraction)
        lastReadAnchorOffset = offset
    }

    /// Swaps the on-screen view for the mode: Read mode shows the rendered-HTML
    /// `ReadModeWebView`; Edit and Source stay on the editor's scroll view.
    private func applyViewMode(_ mode: EditorTextView.ViewMode) {
        guard let containerView else { return }
        if mode == .reading {
            let pendingRestore = pendingReadEntryRestore
            pendingReadEntryRestore = nil
            let read = readView ?? {
                let v = ReadModeWebView()
                v.usesTransparentBackground = usesTranslucentPinnedWindowBackground
                v.frame = NSRect(x: scrollView.frame.minX, y: scrollView.frame.minY,
                                 width: scrollView.frame.width + minimapView.frame.width,
                                 height: scrollView.frame.height)
                v.autoresizingMask = [.width, .height]
                v.isHidden = true
                // Below the floating status bar so counts stay visible.
                containerView.addSubview(v, positioned: .below, relativeTo: statusBar)
                // Route internal navigation through the editor's link resolver
                // (which resolves against this document's directory and opens via
                // NSDocumentController) instead of navigating the webview.
                v.onOpenWikiLink = { [weak self, weak v] target in
                    guard let self else { return }
                    if let line = self.editor.sourceLine(forPageLocalWikiTarget: target) {
                        v?.setScrollPosition(line: line, fraction: 0)
                    } else {
                        self.editor.followWikiLink(target)
                    }
                }
                v.onOpenInternalLink = { [weak self] in self?.editor.followLinkDestination($0) }
                // Keep Edit visible until the HTML and its restored viewport are
                // ready, then exchange the two surfaces once.
                v.onLoadFinished = { [weak self] in
                    guard let self, self.editor.viewMode == .reading,
                          let read = self.readView else { return }
                    read.isHidden = false
                    self.minimapView?.isHidden = true
                    self.scrollView.isHidden = true
                    self.editor.window?.makeFirstResponder(read)
                }
                readView = v
                return v
            }()
            if let pendingRestore {
                read.setPendingScrollRestore(line: pendingRestore.line,
                                             fraction: pendingRestore.fraction)
            }
            read.render(markdown: editor.rawSource,
                        theme: editor.theme,
                        callouts: mergedCallouts,
                        baseURL: documentDirectory,
                        options: renderOptions,
                        copyStrings: readModeCopyStrings)
        } else {
            if let read = readView, !read.isHidden {
                // Capture the Read position while it is still visible. The
                // editor remains hidden until its TextKit 2 viewport has been
                // positioned, so the asynchronous JS round-trip cannot expose
                // the old location followed by a visible correction hop.
                read.readScrollPosition { [weak self] position in
                    guard let self, self.editor.viewMode != .reading else { return }
                    var targetOffset: Int?
                    if let position {
                        let spans = ReadModeAnchors.topLevelBlockSpans(for: self.editor.rawSource)
                        let span = spans.first(where: { $0.startLine == position.line })
                            ?? spans.last(where: { $0.startLine <= position.line })
                        if let span {
                            let lineCount = Double(span.endLine - span.startLine + 1)
                            let targetLine = min(
                                span.endLine,
                                span.startLine + Int((position.fraction * lineCount).rounded())
                            )
                            targetOffset = self.editor.offset(forLine: targetLine)
                        }
                    }
                    if let offset = targetOffset ?? self.lastReadAnchorOffset {
                        self.editor.scrollCharacterToTop(offset)
                    }
                    self.swapToEditor()
                }
            } else {
                swapToEditor()
            }
        }
    }

    private func swapToEditor() {
        readView?.isHidden = true
        scrollView.isHidden = false
        minimapView?.isHidden = !AppSettings.showMinimap
        editor.window?.makeFirstResponder(editor)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.needsDisplay = true
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
                    options: renderOptions,
                    copyStrings: readModeCopyStrings)
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
        ReadRenderOptions(features: AppSettings.markdownFeatures,
                         preserveBlankLines: AppSettings.renderBlankLinesAsBreaks,
                         allowRemoteImages: !AppSettings.blockExternalImages,
                         maxContentWidthPoints: Double(editor.maxContentWidthPoints))
    }

    private var readModeCopyStrings: ReadModeCopyStrings {
        ReadModeCopyStrings(
            copyCode: AppCopy.text("Copy code", "复制代码"),
            copied: AppCopy.text("Copied", "已复制"),
            announcement: AppCopy.text("Code copied", "代码已复制")
        )
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
    var onAppearanceChange: (() -> Void)?
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
        onAppearanceChange?()
    }
}

/// A controlled boundary between the unified titlebar and document surface.
/// AppKit's native titlebar separator is too faint on near-white backgrounds,
/// so this hairline keeps the same hierarchy in both appearances.
private final class DocumentSurfaceSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.20).cgColor
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
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard let window = window as? DocumentWindow else { return }
        (document as? Document)?.windowDidFailToEnterFullScreen(window)
    }

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
    var prepareForOwnFullScreen: (() -> Void)?
    var pinningMode: WindowPinningMode = .none {
        didSet { applyPinningPresentation() }
    }
    private var isPinningSuspendedForOwnFullScreen = false

    func suspendPinningForOwnFullScreen() {
        isPinningSuspendedForOwnFullScreen = true
        applyPinningPresentation()
    }

    func resumePinningAfterOwnFullScreen() {
        isPinningSuspendedForOwnFullScreen = false
        applyPinningPresentation()
    }

    /// The ordinary document host always retains its primary-window role. In
    /// All-Spaces mode its content is temporarily owned by a dedicated
    /// nonactivating panel that carries the auxiliary collection behavior.
    func applyPinningPresentation() {
        let presentation = PinnedWindowPresentationPolicy.windowPresentation(
            mode: pinningMode,
            isSuspendedForOwnFullScreen: isPinningSuspendedForOwnFullScreen
        )
        level = presentation.floatsAboveNormalWindows ? .floating : .normal

        var behavior: CollectionBehavior = []
        if presentation.joinsAllSpaces {
            behavior.insert(.canJoinAllSpaces)
        }
        if presentation.joinsAllApplications {
            behavior.insert(.canJoinAllApplications)
        }
        if presentation.actsAsFullScreenAuxiliary {
            behavior.insert(.fullScreenAuxiliary)
        }
        if presentation.actsAsPrimaryWindow {
            behavior.insert(.primary)
            behavior.insert(.fullScreenPrimary)
        }
        collectionBehavior = behavior
    }

    override func toggleFullScreen(_ sender: Any?) {
        if !styleMask.contains(.fullScreen) {
            prepareForOwnFullScreen?()
            suspendPinningForOwnFullScreen()
        }
        super.toggleFullScreen(sender)
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

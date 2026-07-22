// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit
import UniformTypeIdentifiers
import FloralMDCore

@MainActor
private protocol DocumentFileRecycling: AnyObject {
    func recycle(_ url: URL, completion: @escaping @MainActor (Error?) -> Void)
}

@MainActor
private final class WorkspaceDocumentFileRecycler: DocumentFileRecycling {
    func recycle(_ url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        NSWorkspace.shared.recycle([url]) { destinations, error in
            let result: Error? = if let error {
                error
            } else if destinations.keys.contains(where: {
                $0.standardizedFileURL == url.standardizedFileURL
            }) {
                nil
            } else {
                NSError(
                    domain: "FloralMD.DocumentTrash",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: AppCopy.text(
                        "The file could not be moved to the Trash.",
                        "无法将文件移到废纸篓。"
                    )]
                )
            }
            // NSWorkspace documents that this completion returns on the same
            // dispatch queue as the caller. recycle() is main-actor-only, so
            // preserve that contract without an unnecessary queue hop.
            MainActor.assumeIsolated {
                completion(result)
            }
        }
    }
}

@MainActor
private final class PendingDocumentTrashRequest {
    let sourceURL: URL
    weak var sourceDocument: Document?

    init(sourceURL: URL, sourceDocument: Document) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.sourceDocument = sourceDocument
    }
}

@MainActor
private final class SystemRecentDocumentStore: RecentDocumentStoring {
    unowned let controller: NSDocumentController
    private var pendingWrite: [URL]?

    init(controller: NSDocumentController) {
        self.controller = controller
    }

    var recentDocumentURLs: [URL] {
        let systemURLs = controller.recentDocumentURLs.map(\.standardizedFileURL)
        guard let pendingWrite else { return systemURLs }
        // AppKit persists recent items asynchronously, and a Debug bundle
        // without CFBundleDocumentTypes can keep reporting the pre-write
        // snapshot. Mirror only our outstanding write so menus update
        // immediately while NSDocumentController remains the durable store.
        if systemURLs == pendingWrite {
            self.pendingWrite = nil
            return systemURLs
        }
        return pendingWrite
    }

    var maximumRecentDocumentCount: Int {
        controller.maximumRecentDocumentCount
    }

    func noteNewRecentDocumentURL(_ url: URL) {
        let candidate = url.standardizedFileURL
        let current = pendingWrite ?? controller.recentDocumentURLs.map(\.standardizedFileURL)
        pendingWrite = Array(([candidate] + current.filter { $0 != candidate })
            .prefix(maximumRecentDocumentCount))
        controller.noteNewRecentDocumentURL(url)
    }

    func clearRecentDocuments() {
        pendingWrite = []
        controller.clearRecentDocuments(nil)
    }
}

/// Custom document controller that registers our Document class for markdown files.
///
/// Without an Info.plist (SPM executable), NSDocumentController's default
/// `openDocument:` is broken because it relies on CFBundleDocumentTypes for
/// type validation. We override it to show the Open panel ourselves and
/// create Document instances directly.
class DocumentController: NSDocumentController {

    static let documentsDidChange = Notification.Name("FloralMDDocumentsDidChange")
    private var isPreparingAutomaticTermination = false
    private let fileRecycler: any DocumentFileRecycling = WorkspaceDocumentFileRecycler()
    private var pendingTrashURLs = Set<URL>()
    private var pendingTrashCloseRequests: [ObjectIdentifier: PendingDocumentTrashRequest] = [:]
    private lazy var recentDocumentHistory = RecentDocumentHistory(
        store: SystemRecentDocumentStore(controller: self)
    )

    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        NotificationCenter.default.post(name: Self.documentsDidChange, object: self)
    }

    // MARK: - New Document Presentation

    /// Command-N is a product-level tab command, not AppKit's preference-driven
    /// `newDocument(_:)`. Only an ordinary document window can receive the new
    /// tab; Quick Capture remains a standalone transient surface.
    @MainActor @objc func newDocumentTab(_ sender: Any?) {
        let source = (currentDocument as? Document).flatMap { document in
            document.isQuickCapture ? nil : document
        }
        createUntitledDocument(from: source, request: .tab)
    }

    /// Command-Shift-N explicitly requests a standalone ordinary window.
    @MainActor @objc func newDocumentWindow(_ sender: Any?) {
        createUntitledDocument(from: nil, request: .window)
    }

    @MainActor
    private func createUntitledDocument(
        from source: Document?,
        request: ApplicationLifecyclePolicy.NewDocumentRequest
    ) {
        do {
            guard let target = try openUntitledDocumentAndDisplay(false) as? Document else {
                return
            }
            let presentation = ApplicationLifecyclePolicy.newDocumentPresentation(
                hasOrdinarySourceWindow: source?.windowControllers.first?.window != nil,
                request: request
            )
            switch presentation {
            case .currentTabGroup:
                guard let source else { return }
                target.prepareForHiddenWindowPresentation()
                activateDocumentTab(target, beside: source)
            case .newWindow:
                target.activateAsStandaloneDocumentWindow()
            }
            NotificationCenter.default.post(name: Self.documentsDidChange, object: self)
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    // MARK: - Application Termination

    override func reviewUnsavedDocuments(withAlertTitle title: String?,
                                         cancellable: Bool,
                                         delegate: Any?,
                                         didReviewAllSelector: Selector?,
                                         contextInfo: UnsafeMutableRawPointer?) {
        documents.compactMap { $0 as? Document }
            .forEach { $0.prepareForUnsavedDocumentReview() }

        // AppKit can enter this override using the dirty state from before our
        // synchronous untitled reconciliation. If every live document is now
        // clean, complete the public callback instead of asking `super` to act
        // on that stale decision.
        if !documents.contains(where: { $0.isDocumentEdited || $0.hasUnautosavedChanges }) {
            if finishTerminationReview(delegate: delegate,
                                       selector: didReviewAllSelector,
                                       contextInfo: contextInfo) {
                return
            }
        }

        guard AppSettings.autoSaveWithVersions,
              !isPreparingAutomaticTermination else {
            continueTerminationReview(withAlertTitle: title,
                                      cancellable: cancellable,
                                      delegate: delegate,
                                      didReviewAllSelector: didReviewAllSelector,
                                      contextInfo: contextInfo)
            return
        }

        let fileBackedDocuments = documents.compactMap { document -> Document? in
            guard let document = document as? Document,
                  document.fileURL != nil,
                  document.isDocumentEdited || document.hasUnautosavedChanges else { return nil }
            return document
        }
        guard !fileBackedDocuments.isEmpty else {
            continueTerminationReview(withAlertTitle: title,
                                      cancellable: cancellable,
                                      delegate: delegate,
                                      didReviewAllSelector: didReviewAllSelector,
                                      contextInfo: contextInfo)
            return
        }

        isPreparingAutomaticTermination = true
        saveBeforeTermination(fileBackedDocuments, index: 0) { [weak self] saveSucceeded in
            guard let self else { return }
            self.isPreparingAutomaticTermination = false
            let stillHasUnsavedDocuments = self.documents.contains {
                $0.isDocumentEdited || $0.hasUnautosavedChanges
            }
            if DocumentSavePolicy.shouldCompleteAutomaticTerminationReview(
                saveSucceeded: saveSucceeded,
                hasUnsavedDocuments: stillHasUnsavedDocuments
            ) {
                // AppKit decided that review was necessary before invoking this
                // method. Calling super after our asynchronous saves reuses that
                // stale decision and presents a Save/Revert sheet even though
                // every document is now clean. Complete the documented delegate
                // callback directly only after re-verifying the live documents.
                let didFinish = self.finishTerminationReview(
                    delegate: delegate,
                    selector: didReviewAllSelector,
                    contextInfo: contextInfo
                )
                if !didFinish {
                    self.continueTerminationReview(withAlertTitle: title,
                                                   cancellable: cancellable,
                                                   delegate: delegate,
                                                   didReviewAllSelector: didReviewAllSelector,
                                                   contextInfo: contextInfo)
                }
            } else {
                self.continueTerminationReview(withAlertTitle: title,
                                               cancellable: cancellable,
                                               delegate: delegate,
                                               didReviewAllSelector: didReviewAllSelector,
                                               contextInfo: contextInfo)
            }
        }
    }

    private func saveBeforeTermination(_ documents: [Document], index: Int,
                                       completion: @escaping (Bool) -> Void) {
        guard index < documents.count else {
            completion(true)
            return
        }
        documents[index].saveBeforeAutomaticTermination { [weak self] error in
            guard error == nil else {
                completion(false)
                return
            }
            self?.saveBeforeTermination(documents, index: index + 1, completion: completion)
        }
    }

    private func finishTerminationReview(delegate: Any?,
                                         selector: Selector?,
                                         contextInfo: UnsafeMutableRawPointer?) -> Bool {
        guard let delegate = delegate as? NSObject,
              let selector,
              delegate.responds(to: selector) else { return false }
        typealias ReviewCallback = @convention(c) (
            AnyObject, Selector, NSDocumentController, Bool, UnsafeMutableRawPointer?
        ) -> Void
        let callback = unsafeBitCast(delegate.method(for: selector), to: ReviewCallback.self)
        callback(delegate, selector, self, true, contextInfo)
        return true
    }

    private func continueTerminationReview(withAlertTitle title: String?,
                                           cancellable: Bool,
                                           delegate: Any?,
                                           didReviewAllSelector: Selector?,
                                           contextInfo: UnsafeMutableRawPointer?) {
        super.reviewUnsavedDocuments(withAlertTitle: title,
                                     cancellable: cancellable,
                                     delegate: delegate,
                                     didReviewAllSelector: didReviewAllSelector,
                                     contextInfo: contextInfo)
    }

    // MARK: - Type Registration

    override var documentClassNames: [String] {
        ["Document"]
    }

    override var defaultType: String? {
        "net.daringfireball.markdown"
    }

    /// Debug intentionally omits CFBundleDocumentTypes, which makes AppKit's
    /// default recent-document limit zero. Declare the product's existing
    /// five-item system-list limit here so Debug and Production exercise the
    /// same Open Recent behavior.
    nonisolated override var maximumRecentDocumentCount: Int {
        5
    }

    override func documentClass(forType typeName: String) -> AnyClass? {
        Document.self
    }

    override func typeForContents(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "mdown" || ext == "mkd" {
            return "net.daringfireball.markdown"
        }
        return "public.plain-text"
    }

    // MARK: - Open Document (manual implementation)

    /// Completely replaces NSDocumentController's openDocument: because the
    /// default implementation refuses to show the panel without Info.plist
    /// type registrations.
    @MainActor
    override func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Allow all files — our read(from:ofType:) handles UTF-8 decoding.
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        let sourceDocument = currentDocument as? Document

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.openDocument(at: url, from: sourceDocument, requestsNewWindow: false)
        }
    }

    /// Resolves the product-level presentation before entering AppKit's
    /// document-loading API. File location never decides tab membership.
    @MainActor
    func openDocument(at url: URL,
                      from source: Document?,
                      requestsNewWindow: Bool,
                      completion: (@MainActor (Error?) -> Void)? = nil) {
        let presentation = ApplicationLifecyclePolicy.documentOpenPresentation(
            hasSourceWindow: source?.windowControllers.first?.window != nil,
            requestsNewWindow: requestsNewWindow
        )
        switch presentation {
        case .currentTabGroup:
            guard let source else {
                completion?(NSError(
                    domain: "FloralMD.DocumentOpen",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: AppCopy.text(
                        "The current document window is no longer available.",
                        "当前文档窗口已不可用。"
                    )]
                ))
                return
            }
            openDocumentTab(at: url, from: source, completion: completion)
        case .newWindow:
            openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error {
                    NSAlert(error: error).runModal()
                }
                completion?(error)
            }
        }
    }

    /// Routes a recent item through the same current-tab-group semantics as
    /// Command-O. A file can disappear after the menu was built, so validate
    /// again at activation time and remove only the failed entry.
    @MainActor
    func openRecentDocument(at url: URL, from source: Document?) {
        guard recentDocumentHistory.containsAvailableDocument(at: url) else {
            presentUnavailableRecentDocumentError()
            return
        }
        openDocument(at: url, from: source, requestsNewWindow: false) { [weak self] error in
            guard let self, error != nil else { return }
            self.recentDocumentHistory.removeDocument(at: url)
        }
    }

    @MainActor
    func availableRecentDocumentURLs() -> [URL] {
        recentDocumentHistory.availableDocumentURLs()
    }

    @MainActor
    func clearRecentDocumentHistory() {
        recentDocumentHistory.clear()
    }

    @MainActor
    private func presentUnavailableRecentDocumentError() {
        let error = NSError(
            domain: "FloralMD.RecentDocument",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: AppCopy.text(
                "The recent file was moved, deleted, or is no longer readable.",
                "最近使用的文件已被移动、删除或不再可读。"
            )]
        )
        NSAlert(error: error).runModal()
    }

    // MARK: - Untitled Window Cleanup
    //
    // Apple's documented single funnel for opening an existing file — the Open
    // panel, Recent Items, and drag-and-drop all call this — so hooking it
    // here catches every "open another file" path in one place.
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            if let document, error == nil {
                self.closeLastUntouchedUntitledWindow(keeping: document)
                if let fileURL = document.fileURL {
                    self.recentDocumentHistory.recordOpenedDocument(at: fileURL)
                }
            }
            NotificationCenter.default.post(name: Self.documentsDidChange, object: self)
            completionHandler(document, alreadyOpen, error)
        }
    }

    /// Opens a file as a native tab beside `source`, or activates its existing
    /// document tab. NSDocument remains the owner of saving and dirty state.
    @MainActor
    func openDocumentTab(at url: URL,
                         from source: Document,
                         completion: (@MainActor (Error?) -> Void)? = nil) {
        // A sidebar open is always destined for an existing tab group. Keep a
        // new document hidden until that membership is established so it can
        // never appear first as a standalone window.
        openDocument(withContentsOf: url, display: false) { document, alreadyOpen, error in
            if let error {
                NSAlert(error: error).runModal()
                completion?(error)
                return
            }
            guard let target = document as? Document else {
                let error = NSError(
                    domain: "FloralMD.DocumentOpen",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: AppCopy.text(
                        "The document could not be opened.",
                        "无法打开文档。"
                    )]
                )
                completion?(error)
                return
            }
            if alreadyOpen {
                self.activateExistingDocument(target)
                completion?(nil)
                return
            }
            target.prepareForHiddenWindowPresentation()
            self.activateDocumentTab(target, beside: source)
            completion?(nil)
        }
    }

    @MainActor
    private func activateExistingDocument(_ document: Document) {
        if !document.activateAllSpacesPinnedPanelIfPresented() {
            document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        }
        document.refreshNavigationSidebar()
    }

    @MainActor
    func activateDocumentTab(_ target: Document, beside source: Document) {
        guard let targetWindow = target.windowControllers.first?.window else { return }
        if target !== source, let sourceWindow = source.windowControllers.first?.window {
            let inheritedPinningMode = source.windowPinningMode
            let activatedIncrementallyInAllSpaces = inheritedPinningMode == .allSpaces
                && source.activateDocumentIncrementallyInAllSpaces(target)
            let completion = ApplicationLifecyclePolicy.hiddenDocumentPresentationCompletion(
                activatedIncrementallyInAllSpaces: activatedIncrementallyInAllSpaces
            )
            if activatedIncrementallyInAllSpaces {
                return
            }
            source.prepareForNativeTabMutation()
            target.prepareForNativeTabMutation()
            target.applyInheritedOrdinaryPinningMode(inheritedPinningMode)
            let groupedWindows = targetWindow.tabGroup?.windows ?? targetWindow.tabbedWindows ?? []
            if !groupedWindows.contains(sourceWindow) {
                sourceWindow.addTabbedWindow(targetWindow, ordered: .above)
            }
            targetWindow.makeKeyAndOrderFront(nil)
            if inheritedPinningMode == .allSpaces {
                target.setPinningMode(inheritedPinningMode)
            }
            if completion == .afterNativeTabActivation {
                target.finishHiddenWindowPresentationSetup()
            }
        } else {
            if !target.activateAllSpacesPinnedPanelIfPresented() {
                targetWindow.makeKeyAndOrderFront(nil)
            }
        }
        // Existing-document activation did not load hidden content and only
        // needs the current navigation selection refreshed.
        if target === source {
            target.refreshNavigationSidebar()
        }
    }

    /// The file tree and titlebar share this entry point. Open documents move
    /// through their NSDocument owner; unopened files use the same validation
    /// and collision rules without manufacturing a second document instance.
    @MainActor
    func renameFile(at url: URL,
                    proposedStem: String,
                    from source: Document,
                    completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let request: DocumentFileRenameRequest
        do {
            request = try DocumentFileRenameRequest(
                sourceURL: url,
                proposedStem: proposedStem
            )
        } catch {
            completion(.failure(localizedDocumentRenameError(error)))
            return
        }

        let standardizedSource = url.standardizedFileURL
        if let openDocument = documents.compactMap({ $0 as? Document }).first(where: {
            $0.fileURL?.standardizedFileURL == standardizedSource
        }) {
            openDocument.performFileRename(request, completion: completion)
            return
        }

        do {
            let destination = try DocumentFileRenameOperation.renameUnopenedFile(request)
            noteNewRecentDocumentURL(destination)
            NotificationCenter.default.post(name: Self.documentsDidChange, object: self)
            source.refreshNavigationSidebar()
            completion(.success(destination))
        } catch {
            completion(.failure(localizedDocumentRenameError(error)))
        }
    }

    @MainActor
    func canMoveFileToTrash(at url: URL) -> Bool {
        let source = url.standardizedFileURL
        guard !pendingTrashURLs.contains(source),
              (try? DocumentFileTrashOperation.validateSource(source)) != nil else { return false }
        return openDocument(at: source)?.canBeginFileTrashOperation ?? true
    }

    /// Moves one Markdown file through the system Trash. Open documents first
    /// receive the standard NSDocument close review, so Save / Don't Save /
    /// Cancel remains the sole owner of unsaved-buffer policy.
    @MainActor
    func moveFileToTrash(at url: URL, from sourceDocument: Document) {
        let source = url.standardizedFileURL
        guard !pendingTrashURLs.contains(source) else { return }
        do {
            try DocumentFileTrashOperation.validateSource(source)
        } catch {
            sourceDocument.presentFileOperationError(localizedDocumentTrashError(error))
            refreshAfterFileOperation(sourceDocument: sourceDocument)
            return
        }

        pendingTrashURLs.insert(source)
        guard let openDocument = openDocument(at: source) else {
            recycleApprovedFile(at: source, openDocument: nil, sourceDocument: sourceDocument)
            return
        }
        guard openDocument.canBeginFileTrashOperation else {
            pendingTrashURLs.remove(source)
            sourceDocument.presentFileOperationError(NSError(
                domain: "FloralMD.DocumentTrash",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: AppCopy.text(
                    "Finish resolving the file's external changes before moving it to the Trash.",
                    "请先处理文件的外部修改，再将它移到废纸篓。"
                )]
            ))
            return
        }

        let identifier = ObjectIdentifier(openDocument)
        pendingTrashCloseRequests[identifier] = PendingDocumentTrashRequest(
            sourceURL: source,
            sourceDocument: sourceDocument
        )
        openDocument.canClose(
            withDelegate: self,
            shouldClose: #selector(document(_:shouldMoveToTrash:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(_ document: NSDocument,
                                shouldMoveToTrash shouldClose: Bool,
                                contextInfo: UnsafeMutableRawPointer?) {
        guard let openDocument = document as? Document else { return }
        let identifier = ObjectIdentifier(openDocument)
        guard let request = pendingTrashCloseRequests.removeValue(forKey: identifier) else {
            return
        }
        guard shouldClose else {
            pendingTrashURLs.remove(request.sourceURL)
            return
        }
        recycleApprovedFile(
            at: request.sourceURL,
            openDocument: openDocument,
            sourceDocument: request.sourceDocument ?? openDocument
        )
    }

    private func recycleApprovedFile(at url: URL,
                                     openDocument: Document?,
                                     sourceDocument: Document) {
        do {
            try DocumentFileTrashOperation.validateSource(url)
        } catch {
            pendingTrashURLs.remove(url)
            sourceDocument.presentFileOperationError(localizedDocumentTrashError(error))
            refreshAfterFileOperation(sourceDocument: sourceDocument)
            return
        }
        if let openDocument, !openDocument.beginFileTrashOperation() {
            pendingTrashURLs.remove(url)
            sourceDocument.presentFileOperationError(NSError(
                domain: "FloralMD.DocumentTrash",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: AppCopy.text(
                    "Finish resolving the file's external changes before moving it to the Trash.",
                    "请先处理文件的外部修改，再将它移到废纸篓。"
                )]
            ))
            return
        }

        fileRecycler.recycle(url) { [weak self, weak openDocument, weak sourceDocument] error in
            guard let self else { return }
            self.pendingTrashURLs.remove(url)
            if let error {
                openDocument?.finishFileTrashOperation(succeeded: false)
                sourceDocument?.presentFileOperationError(error)
                if let sourceDocument {
                    self.refreshAfterFileOperation(sourceDocument: sourceDocument)
                }
                return
            }

            openDocument?.finishFileTrashOperation(succeeded: true)
            openDocument?.close()
            if openDocument == nil, let sourceDocument {
                self.refreshAfterFileOperation(sourceDocument: sourceDocument)
            }
        }
    }

    private func openDocument(at url: URL) -> Document? {
        documents.compactMap { $0 as? Document }.first {
            $0.fileURL?.standardizedFileURL == url.standardizedFileURL
        }
    }

    private func refreshAfterFileOperation(sourceDocument: Document) {
        NotificationCenter.default.post(name: Self.documentsDidChange, object: self)
        sourceDocument.refreshNavigationSidebar()
    }

    /// Closes the most-recently-opened blank Untitled window the user never
    /// typed into — e.g. the automatic blank document from launch — once a
    /// real file opens. Only the last one, so opening several Untitled
    /// windows on purpose still leaves the earlier ones alone.
    /// `isDocumentEdited` already tracks "untyped": edits call
    /// `updateChangeCount` (`EditorTextView+EditFlow.swift`), so an untouched
    /// Untitled document is never marked edited.
    private func closeLastUntouchedUntitledWindow(keeping opened: NSDocument) {
        let stale = documents.last { doc in
            guard let doc = doc as? Document, doc !== opened else { return false }
            return ApplicationLifecyclePolicy.shouldCloseUntouchedUntitledAfterOpeningExistingFile(
                hasFileURL: doc.fileURL != nil,
                isDocumentEdited: doc.isDocumentEdited
            )
        }
        stale?.close()
    }
}

private func localizedDocumentTrashError(_ error: Error) -> Error {
    guard let trashError = error as? DocumentFileTrashError else { return error }
    let message: String = switch trashError {
    case .sourceMissing:
        AppCopy.text(
            "The original file no longer exists. Refresh the sidebar and try again.",
            "原文件已不存在，请刷新侧栏后重试。"
        )
    case .sourceIsDirectory:
        AppCopy.text(
            "This version moves Markdown files to the Trash, not folders.",
            "当前版本只能将 Markdown 文件移到废纸篓，不支持文件夹。"
        )
    }
    return NSError(
        domain: "FloralMD.DocumentTrash",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

func localizedDocumentRenameError(_ error: Error) -> Error {
    guard let renameError = error as? DocumentFileRenameError else { return error }
    let message: String = switch renameError {
    case .emptyName:
        AppCopy.text("Enter a file name.", "请输入文件名。")
    case .reservedName:
        AppCopy.text("A file cannot be named “.” or “..”.", "文件名不能是“.”或“..”。")
    case .pathSeparator:
        AppCopy.text("A file name cannot contain a path separator.", "文件名不能包含路径分隔符。")
    case .surroundingWhitespace:
        AppCopy.text("Remove spaces from the beginning or end of the file name.",
                     "请删除文件名开头或结尾的空格。")
    case .extensionChanged(let expected):
        AppCopy.text("Renaming keeps the .\(expected) extension. Edit only the name before it.",
                     "重命名会保留 .\(expected) 扩展名，请只修改扩展名前的名称。")
    case .directoryChanged:
        AppCopy.text("Rename keeps the file in its current folder. Use Move to change folders.",
                     "重命名会保留当前文件夹；如需更改文件夹，请使用“移动”。")
    case .sourceMissing:
        AppCopy.text("The original file no longer exists. Refresh the sidebar and try again.",
                     "原文件已不存在，请刷新侧栏后重试。")
    case .sourceIsDirectory:
        AppCopy.text("This version can rename files only, not folders.",
                     "当前版本只支持重命名文件，不支持文件夹。")
    case .destinationExists:
        AppCopy.text("A file with that name already exists in this folder.",
                     "此文件夹中已存在同名文件。")
    case .rollbackFailed(let destination):
        AppCopy.text(
            "The rename could not be completed or rolled back. The document remains at \(destination.path).",
            "重命名失败且无法回滚，文档当前保留在 \(destination.path)。"
        )
    }
    return NSError(
        domain: "FloralMD.DocumentRename",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

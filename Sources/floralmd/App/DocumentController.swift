import AppKit
import UniformTypeIdentifiers
import FloralMDCore

/// Custom document controller that registers our Document class for markdown files.
///
/// Without an Info.plist (SPM executable), NSDocumentController's default
/// `openDocument:` is broken because it relies on CFBundleDocumentTypes for
/// type validation. We override it to show the Open panel ourselves and
/// create Document instances directly.
class DocumentController: NSDocumentController {

    static let documentsDidChange = Notification.Name("FloralMDDocumentsDidChange")
    private var isPreparingAutomaticTermination = false

    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        NotificationCenter.default.post(name: Self.documentsDidChange, object: self)
    }

    // MARK: - Application Termination

    override func reviewUnsavedDocuments(withAlertTitle title: String?,
                                         cancellable: Bool,
                                         delegate: Any?,
                                         didReviewAllSelector: Selector?,
                                         contextInfo: UnsafeMutableRawPointer?) {
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

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error = error {
                    NSAlert(error: error).runModal()
                }
            }
        }
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
            }
            NotificationCenter.default.post(name: Self.documentsDidChange, object: self)
            completionHandler(document, alreadyOpen, error)
        }
    }

    /// Opens a file as a native tab beside `source`, or activates its existing
    /// document tab. NSDocument remains the owner of saving and dirty state.
    @MainActor
    func openDocumentTab(at url: URL, from source: Document) {
        // A sidebar open is always destined for an existing tab group. Keep a
        // new document hidden until that membership is established so it can
        // never appear first as a standalone window.
        openDocument(withContentsOf: url, display: false) { document, _, error in
            if let error {
                NSAlert(error: error).runModal()
                return
            }
            guard let target = document as? Document else { return }
            target.prepareForHiddenWindowPresentation()
            self.activateDocumentTab(target, beside: source)
        }
    }

    @MainActor
    func activateDocumentTab(_ target: Document, beside source: Document) {
        guard let targetWindow = target.windowControllers.first?.window else { return }
        if target !== source, let sourceWindow = source.windowControllers.first?.window {
            let inheritedPinningMode = source.windowPinningMode
            if inheritedPinningMode == .allSpaces,
               source.activateDocumentIncrementallyInAllSpaces(target) {
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
        } else {
            if !target.activateAllSpacesPinnedPanelIfPresented() {
                targetWindow.makeKeyAndOrderFront(nil)
            }
        }
        target.refreshNavigationSidebar()
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

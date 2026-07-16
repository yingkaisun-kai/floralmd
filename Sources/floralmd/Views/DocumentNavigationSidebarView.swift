import AppKit
import FloralMDCore

/// Left-side repository file tree and read-only Git status.
/// Open documents are intentionally left to macOS's native window tabs.
final class DocumentNavigationSidebarView: QuietSidebarBackgroundView,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    static let expandedWidth: CGFloat = 230
    static let collapsedWidth: CGFloat = 0
    private static let modeControlWidth: CGFloat = expandedWidth - 20

    private enum Mode { case files, git }
    private struct FileTreeRow {
        let entry: MarkdownDirectoryEntry
        let depth: Int
        let markdownCount: Int?
    }

    private final class RenameSession {
        let sourceURL: URL
        weak var field: NSTextField?
        weak var originalField: NSTextField?
        var isCommitting = false

        init(sourceURL: URL, field: NSTextField, originalField: NSTextField) {
            self.sourceURL = sourceURL
            self.field = field
            self.originalField = originalField
        }
    }

    private final class RenameKeyMonitorToken: @unchecked Sendable {
        let value: Any

        init(_ value: Any) { self.value = value }
        deinit { NSEvent.removeMonitor(value) }
    }

    private let modeControl = NSSegmentedControl()
    private let locationLabel = NSTextField(labelWithString: "")
    private let separator = QuietSidebarSeparatorView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var fileRows: [FileTreeRow] = []
    private var currentFileURL: URL?
    private var fileRootURL: URL?
    private var expandedDirectories = Set<URL>()
    private var gitSnapshot: GitRepositorySnapshot?
    private var displayedGitSnapshot: GitRepositorySnapshot?
    private var currentBufferDiffersFromHEAD: Bool?
    private var mode: Mode = .files
    private var renameSession: RenameSession?
    private var renameKeyMonitor: RenameKeyMonitorToken?
    private var pendingOpenURL: URL?
    private(set) var isExpanded = true

    var onOpenFile: ((URL) -> Void)?
    var onRenameFile: ((URL, String,
                        @escaping @MainActor (Result<URL, Error>) -> Void) -> Void)?
    var onWidthChange: ((CGFloat, TimeInterval) -> Void)?

    init(frame frameRect: NSRect) {
        super.init(role: .files)
        frame = frameRect
        autoresizingMask = [.height]

        modeControl.segmentCount = 2
        modeControl.segmentStyle = .capsule
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        locationLabel.font = .systemFont(ofSize: 11, weight: .medium)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.maximumNumberOfLines = 1
        locationLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 26
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateSelection(_:))
        tableView.doubleAction = #selector(beginRenameFromDoubleClick(_:))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(modeControl)
        addSubview(locationLabel)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            modeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            // Keep the segmented control at its expanded width while the sidebar
            // collapses. Compressing NSSegmentedControl to zero makes its segment
            // widths stick in a corrupted arrangement after the sidebar reopens.
            modeControl.widthAnchor.constraint(equalToConstant: Self.modeControlWidth),
            modeControl.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            modeControl.heightAnchor.constraint(equalToConstant: 24),
            locationLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            locationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            locationLabel.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: locationLabel.bottomAnchor, constant: 5),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage),
                                               name: .appLanguageDidChange, object: nil)
        refreshLanguage()
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    func toggleExpanded() {
        setExpanded(!isExpanded, animated: true)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard let superview else { return }
        guard isExpanded != expanded else { return }
        isExpanded = expanded

        let contentViews = [modeControl, locationLabel, scrollView]
        if isExpanded {
            isHidden = false
            contentViews.forEach {
                $0.isHidden = false
                $0.alphaValue = 0
            }
        } else {
            // Its frame deliberately stays at the expanded width; hide it before
            // the parent narrows so it cannot draw over the editor during transit.
            modeControl.isHidden = true
            modeControl.alphaValue = 1
        }

        let targetWidth = isExpanded ? Self.expandedWidth : Self.collapsedWidth
        let duration = animated ? 0.22 : 0
        onWidthChange?(targetWidth, duration)

        guard animated else {
            contentViews.forEach {
                $0.isHidden = !isExpanded
                $0.alphaValue = 1
            }
            isHidden = !isExpanded
            superview.layoutSubtreeIfNeeded()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentViews.forEach { $0.animator().alphaValue = isExpanded ? 1 : 0 }
            superview.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isExpanded else { return }
                contentViews.forEach {
                    $0.isHidden = true
                    $0.alphaValue = 1
                }
                // A zero-width view does not clip subviews by default. Hiding
                // the collapsed panel guarantees its separator and controls
                // cannot leak back over the editor after the animation.
                self.isHidden = true
            }
        }
    }

    func refresh(currentFileURL: URL?) {
        self.currentFileURL = currentFileURL?.standardizedFileURL
        // A file-presenter notification or Git refresh can arrive while the
        // user is typing. Do not destroy the field editor; the rename result
        // performs one authoritative refresh after the disk operation ends.
        if renameSession != nil { return }
        gitSnapshot = currentFileURL.flatMap { GitRepository.snapshot(containing: $0) }
        rebuildDisplayedGitSnapshot()
        let fallback = currentFileURL?.deletingLastPathComponent().standardizedFileURL
        let newRoot = gitSnapshot?.rootURL.standardizedFileURL ?? fallback
        if newRoot != fileRootURL {
            fileRootURL = newRoot
            expandedDirectories.removeAll()
        }
        expandPathToCurrentFile()
        rebuildFileRows()
        tableView.reloadData()
        selectCurrentRow()
    }

    /// Applies the editor's in-memory state to the last repository snapshot.
    /// This deliberately avoids launching Git from the per-edit path.
    func updateCurrentBufferGitState(differsFromHEAD: Bool) {
        guard currentBufferDiffersFromHEAD != differsFromHEAD else { return }
        currentBufferDiffersFromHEAD = differsFromHEAD
        rebuildDisplayedGitSnapshot()
        updateLocationLabel()
        tableView.reloadData()
    }

    private func rebuildDisplayedGitSnapshot() {
        guard let currentBufferDiffersFromHEAD, let currentFileURL else {
            displayedGitSnapshot = gitSnapshot
            return
        }
        displayedGitSnapshot = gitSnapshot?.overlayingWorkTreeState(
            for: currentFileURL,
            differsFromHEAD: currentBufferDiffersFromHEAD
        )
    }

    private func rebuildFileRows() {
        guard let fileRootURL else {
            fileRows = []
            updateLocationLabel()
            return
        }
        var rows: [FileTreeRow] = []
        func appendChildren(of directory: URL, depth: Int) {
            for entry in MarkdownDirectory.entries(at: directory) {
                let count = entry.isDirectory ? MarkdownDirectory.markdownCount(in: entry.url) : nil
                rows.append(FileTreeRow(entry: entry, depth: depth, markdownCount: count))
                if entry.isDirectory,
                   expandedDirectories.contains(entry.url.standardizedFileURL) {
                    appendChildren(of: entry.url.standardizedFileURL, depth: depth + 1)
                }
            }
        }
        appendChildren(of: fileRootURL, depth: 0)
        fileRows = rows
        updateLocationLabel()
    }

    private func expandPathToCurrentFile() {
        guard let root = fileRootURL?.standardizedFileURL,
              var directory = currentFileURL?.deletingLastPathComponent().standardizedFileURL,
              directory.path.hasPrefix(root.path) else { return }
        while directory != root {
            expandedDirectories.insert(directory)
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent != directory else { break }
            directory = parent
        }
    }

    private func updateLocationLabel() {
        locationLabel.textColor = .secondaryLabelColor
        switch mode {
        case .files:
            locationLabel.stringValue = fileRootURL?.lastPathComponent
                ?? AppCopy.text("No folder", "无文件夹")
            locationLabel.toolTip = fileRootURL?.path
        case .git:
            guard let gitSnapshot = displayedGitSnapshot else {
                locationLabel.stringValue = AppCopy.text("No Git repository", "未找到 Git 仓库")
                locationLabel.toolTip = nil
                return
            }
            let count = gitSnapshot.changes.count
            locationLabel.stringValue = "\(gitSnapshot.branch) · \(count)"
            locationLabel.toolTip = gitSnapshot.rootURL.path
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch mode {
        case .files: fileRows.count
        case .git: displayedGitSnapshot?.changes.count ?? 0
        }
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("NavigationCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? QuietSidebarCellView) ?? {
            let cell = QuietSidebarCellView()
            cell.identifier = id
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = image
            cell.addSubview(image)
            let field = QuietSidebarLabel()
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = field
            cell.addSubview(field)
            let detail = QuietSidebarLabel()
            detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            detail.textColor = .tertiaryLabelColor
            detail.alignment = .right
            detail.translatesAutoresizingMaskIntoConstraints = false
            cell.detailTextField = detail
            cell.addSubview(detail)
            let imageLeading = image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7)
            cell.imageLeadingConstraint = imageLeading
            NSLayoutConstraint.activate([
                imageLeading,
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
                field.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            ])
            return cell
        }()

        switch mode {
        case .files:
            let treeRow = fileRows[row]
            let entry = treeRow.entry
            if renameSession?.originalField !== cell.textField {
                configureReadOnlyNameField(cell.textField)
            }
            cell.imageLeadingConstraint?.constant = 7 + CGFloat(treeRow.depth) * 14
            let disclosure = entry.isDirectory
                ? (expandedDirectories.contains(entry.url.standardizedFileURL) ? "▾ " : "▸ ")
                : ""
            cell.textField?.stringValue = disclosure + entry.url.lastPathComponent
            cell.textField?.setAccessibilityIdentifier(
                entry.isDirectory ? "fileTreeFolderName" : "fileTreeFileName"
            )
            let state = gitState(for: entry.url, isDirectory: entry.isDirectory)
            let stateColor = state.map(color(for:))
            cell.detailTextField?.isHidden = false
            cell.detailTextField?.stringValue = entry.isDirectory
                ? treeRow.markdownCount.map(String.init) ?? ""
                : state?.badge ?? ""
            cell.detailTextField?.textColor = stateColor ?? .tertiaryLabelColor
            cell.textField?.textColor = stateColor ?? .labelColor
            let symbol = entry.isDirectory ? "folder" : "doc.text"
            cell.imageView?.contentTintColor = stateColor ?? .secondaryLabelColor
            cell.imageView?.image = NSImage(systemSymbolName: symbol,
                                            accessibilityDescription: entry.isDirectory
                                                ? AppCopy.text("Folder", "文件夹")
                                                : AppCopy.text("Markdown document", "Markdown 文档"))
        case .git:
            guard let change = displayedGitSnapshot?.changes[row] else { return cell }
            cell.imageLeadingConstraint?.constant = 7
            cell.detailTextField?.isHidden = true
            cell.textField?.stringValue = "\(change.badge)  \(change.path)"
            cell.textField?.textColor = change.isIgnored ? .tertiaryLabelColor : .labelColor
            cell.imageView?.image = NSImage(systemSymbolName: "doc.text",
                                            accessibilityDescription: AppCopy.text("Changed file", "变更文件"))
            cell.imageView?.contentTintColor = color(for: change)
        }
        return cell
    }

    private func configureReadOnlyNameField(_ field: NSTextField?) {
        field?.delegate = nil
        field?.target = nil
        field?.action = nil
        field?.isEditable = false
        field?.isSelectable = false
        field?.isBordered = false
        field?.drawsBackground = false
        field?.backgroundColor = .clear
        field?.focusRingType = .none
    }

    private func gitState(for url: URL, isDirectory: Bool) -> GitPathState? {
        guard let snapshot = displayedGitSnapshot else { return nil }
        let rootPath = snapshot.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        return snapshot.state(forRelativePath: relative, isDirectory: isDirectory)
    }

    private func color(for state: GitPathState) -> NSColor {
        switch state {
        case .ignored: return .tertiaryLabelColor
        case .untracked: return .systemGreen
        case .staged: return .systemBlue
        case .modified: return .systemOrange
        case .conflicted: return .systemRed
        }
    }

    private func color(for change: GitFileChange) -> NSColor {
        color(for: change.pathState)
    }

    @objc private func refreshLanguage() {
        modeControl.setLabel(AppCopy.text("Files", "文件"), forSegment: 0)
        modeControl.setLabel("Git", forSegment: 1)
        updateLocationLabel()
        if renameSession == nil { tableView.reloadData() }
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .git : .files
        if mode == .git, let currentFileURL {
            gitSnapshot = GitRepository.snapshot(containing: currentFileURL)
            rebuildDisplayedGitSnapshot()
        }
        updateLocationLabel()
        tableView.reloadData()
        selectCurrentRow()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        QuietSidebarRowView()
    }

    @objc private func activateSelection(_ sender: Any?) {
        if renameSession != nil {
            // Return from Accessibility can arrive as the table's action rather
            // than a field-editor command. Mouse blur has already been handled
            // by the active event monitor, so do not inspect currentEvent here:
            // AppKit may leave the earlier double-click there as stale state.
            commitRename()
            return
        }
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 else { return }
        switch mode {
        case .files:
            guard fileRows.indices.contains(row) else { return }
            let entry = fileRows[row].entry
            if entry.isDirectory {
                let directory = entry.url.standardizedFileURL
                if expandedDirectories.contains(directory) {
                    expandedDirectories.remove(directory)
                } else {
                    expandedDirectories.insert(directory)
                }
                rebuildFileRows()
                tableView.reloadData()
                selectCurrentRow()
            } else {
                let target: DocumentFileTreeClickTarget = clickIsInNameField(row: row)
                    ? .name : .rowChrome
                let clickCount = NSApp.currentEvent?.clickCount ?? 1
                switch DocumentFileTreeClickPolicy.action(
                    target: target,
                    clickCount: clickCount
                ) {
                case .delayedOpen:
                    scheduleOpen(entry.url)
                case .openImmediately:
                    cancelPendingOpen()
                    onOpenFile?(entry.url)
                case .beginRename:
                    cancelPendingOpen()
                }
            }
        case .git:
            guard let snapshot = displayedGitSnapshot,
                  snapshot.changes.indices.contains(row) else { return }
            let url = snapshot.rootURL.appendingPathComponent(snapshot.changes[row].path)
            if MarkdownDirectory.isMarkdown(url) { onOpenFile?(url) }
        }
    }

    @objc private func beginRenameFromDoubleClick(_ sender: Any?) {
        cancelPendingOpen()
        guard mode == .files,
              renameSession == nil,
              tableView.clickedRow >= 0,
              fileRows.indices.contains(tableView.clickedRow) else { return }
        let row = tableView.clickedRow
        let entry = fileRows[row].entry
        guard !entry.isDirectory,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? QuietSidebarCellView,
              let field = cell.textField,
              let event = NSApp.currentEvent else { return }

        guard clickIsInNameField(row: row, event: event) else { return }
        beginRename(entry.url, field: field, cell: cell)
    }

    private func clickIsInNameField(row: Int, event: NSEvent? = NSApp.currentEvent) -> Bool {
        guard let event,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? QuietSidebarCellView,
              let field = cell.textField else { return false }
        let clickPoint = tableView.convert(event.locationInWindow, from: nil)
        let nameRect = field.convert(field.bounds, to: tableView).insetBy(dx: -3, dy: -2)
        return nameRect.contains(clickPoint)
    }

    private func scheduleOpen(_ url: URL) {
        cancelPendingOpen()
        pendingOpenURL = url
        perform(#selector(openPendingFile),
                with: nil,
                afterDelay: NSEvent.doubleClickInterval)
    }

    private func cancelPendingOpen() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(openPendingFile),
            object: nil
        )
        pendingOpenURL = nil
    }

    @objc private func openPendingFile() {
        guard let url = pendingOpenURL else { return }
        pendingOpenURL = nil
        onOpenFile?(url)
    }

    private func beginRename(_ url: URL, field: NSTextField, cell: QuietSidebarCellView) {
        let stem = DocumentFileRenameRequest.editableStem(for: url)
        let editor = NSTextField(string: stem)
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.font = field.font
        editor.textColor = field.textColor
        editor.delegate = self
        editor.focusRingType = .exterior
        editor.setAccessibilityIdentifier("fileTreeRenameField")
        field.isHidden = true
        cell.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            editor.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            editor.heightAnchor.constraint(equalToConstant: 22),
        ])
        renameSession = RenameSession(
            sourceURL: url.standardizedFileURL,
            field: editor,
            originalField: field
        )
        installRenameKeyMonitor()
        cell.detailTextField?.isHidden = false
        cell.detailTextField?.stringValue = ".\(url.pathExtension)"
        cell.detailTextField?.textColor = .tertiaryLabelColor
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectedRange = NSRange(
            location: 0,
            length: (stem as NSString).length
        )
        locationLabel.stringValue = AppCopy.text(
            "Return to rename · Escape or click away to cancel",
            "回车重命名 · Esc 或点击别处取消"
        )
        locationLabel.textColor = .secondaryLabelColor
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            if DocumentInlineRenamePolicy.action(for: .returnKey) == .commit {
                commitRename()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if DocumentInlineRenamePolicy.action(for: .escapeKey) == .cancel {
                cancelRename()
            }
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = (notification.userInfo?[NSText.movementUserInfoKey] as? NSNumber)?.intValue
        let keyCode = NSApp.currentEvent?.type == .keyDown ? NSApp.currentEvent?.keyCode : nil
        if DocumentInlineRenamePolicy.action(
            forTextMovement: movement,
            keyCode: keyCode
        ) == .commit {
            commitRename()
            return
        }
        // An Accessibility-confirmed field may report an implementation-defined
        // movement here before the table activation arrives. Mouse, Tab, and
        // window-resign cancellation are handled by explicit event paths.
    }

    private func commitRename() {
        guard let session = renameSession,
              !session.isCommitting,
              let field = session.field,
              let onRenameFile else { return }
        do {
            let request = try DocumentFileRenameRequest(
                sourceURL: session.sourceURL,
                proposedStem: field.stringValue
            )
            if !request.isNoChange,
               !request.isCaseOnlyChange,
               FileManager.default.fileExists(atPath: request.destinationURL.path) {
                throw DocumentFileRenameError.destinationExists
            }
        } catch {
            presentRenameFailure(
                localizedDocumentRenameError(error),
                session: session,
                field: field
            )
            return
        }
        session.isCommitting = true
        field.isEnabled = false
        onRenameFile(session.sourceURL, field.stringValue) { [weak self] result in
            guard let self, self.renameSession === session else { return }
            switch result {
            case .success(let destination):
                self.finishRename(destination: destination)
            case .failure(let error):
                self.presentRenameFailure(error, session: session, field: field)
            }
        }
    }

    private func presentRenameFailure(_ error: Error,
                                      session: RenameSession,
                                      field: NSTextField) {
        session.isCommitting = false
        field.isEnabled = true
        locationLabel.stringValue = error.localizedDescription
        locationLabel.textColor = .systemRed
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(
            location: 0,
            length: (field.stringValue as NSString).length
        )
        NSSound.beep()
    }

    private func installRenameKeyMonitor() {
        renameKeyMonitor = nil
        // This row starts life as an NSTextField label, whose cell does not
        // reliably send an action after it becomes editable. Monitor only the
        // active window and only the two rename commands, then tear it down as
        // soon as the session ends so editor key handling remains untouched.
        let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) {
            [weak self] event in
            guard let self,
                  self.renameSession != nil,
                  event.window === self.window else { return event }
            if event.type != .keyDown {
                if let editor = self.renameSession?.field {
                    let point = editor.convert(event.locationInWindow, from: nil)
                    if !editor.bounds.contains(point) { self.cancelRename() }
                }
                return event
            }
            switch event.keyCode {
            case 36, 76:
                self.commitRename()
                return nil
            case 48, 53:
                self.cancelRename()
                return nil
            default:
                return event
            }
        }
        if let monitor { renameKeyMonitor = RenameKeyMonitorToken(monitor) }
    }

    private func removeRenameKeyMonitor() {
        renameKeyMonitor = nil
    }

    private func cancelRename() {
        guard let session = renameSession else { return }
        session.field?.removeFromSuperview()
        session.originalField?.isHidden = false
        renameSession = nil
        removeRenameKeyMonitor()
        rebuildFileRows()
        tableView.reloadData()
        selectCurrentRow()
    }

    private func finishRename(destination: URL) {
        let source = renameSession?.sourceURL
        renameSession?.field?.removeFromSuperview()
        renameSession?.originalField?.isHidden = false
        renameSession = nil
        removeRenameKeyMonitor()
        if currentFileURL == source {
            currentFileURL = destination.standardizedFileURL
        }
        refresh(currentFileURL: currentFileURL)
    }

    private func selectCurrentRow() {
        guard mode == .files else {
            tableView.deselectAll(nil)
            return
        }
        guard let currentFileURL else {
            tableView.deselectAll(nil)
            return
        }
        let row = fileRows.firstIndex { $0.entry.url.standardizedFileURL == currentFileURL }
        if let row { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { tableView.deselectAll(nil) }
    }
}

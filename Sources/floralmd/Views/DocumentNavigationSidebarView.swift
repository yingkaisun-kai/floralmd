import AppKit
import FloralMDCore

private final class DocumentNavigationTableView: NSTableView {
    var contextMenuForRow: ((Int) -> NSMenu?)?
    var performCommandDelete: (() -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let targetRow = row(at: point)
        guard targetRow >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        window?.makeFirstResponder(self)
        return contextMenuForRow?(targetRow)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51, modifiers == .command, performCommandDelete?() == true {
            return
        }
        super.keyDown(with: event)
    }
}

private final class DocumentNavigationResizeHandle: NSView {
    var currentWidth: (() -> CGFloat)?
    var onResize: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        guard let window, let initialWidth = currentWidth?() else { return }
        let initialX = event.locationInWindow.x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            onResize?(initialWidth + next.locationInWindow.x - initialX)
        }
    }
}

private final class GitModeScopeBar: NSView {
    var onChange: ((DocumentGitMode) -> Void)?
    private let changesButton = NSButton()
    private let historyButton = NSButton()
    private let indicator = NSView()
    private var indicatorCenterConstraint: NSLayoutConstraint?

    var selectedMode: DocumentGitMode = .changes {
        didSet { updateSelection() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [changesButton, historyButton])
        stack.orientation = .horizontal
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (button, action) in [(changesButton, #selector(selectChanges(_:))),
                                 (historyButton, #selector(selectHistory(_:)))] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = action
            button.setButtonType(.momentaryChange)
        }
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.layer?.cornerRadius = 1
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(indicator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: 19),
            indicator.bottomAnchor.constraint(equalTo: bottomAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 24),
            indicator.heightAnchor.constraint(equalToConstant: 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshLanguage()
        updateSelection()
    }

    required init?(coder: NSCoder) { nil }

    func refreshLanguage() {
        changesButton.title = AppCopy.text("Changes", "改动")
        historyButton.title = AppCopy.text("History", "历史")
        setAccessibilityLabel(AppCopy.text("Git views", "Git 视图"))
        changesButton.setAccessibilityLabel(changesButton.title)
        historyButton.setAccessibilityLabel(historyButton.title)
    }

    private func updateSelection() {
        let selected = selectedMode == .changes ? changesButton : historyButton
        changesButton.contentTintColor = selectedMode == .changes
            ? .controlAccentColor : .secondaryLabelColor
        historyButton.contentTintColor = selectedMode == .history
            ? .controlAccentColor : .secondaryLabelColor
        indicatorCenterConstraint?.isActive = false
        indicatorCenterConstraint = indicator.centerXAnchor.constraint(equalTo: selected.centerXAnchor)
        indicatorCenterConstraint?.isActive = true
    }

    @objc private func selectChanges(_ sender: Any?) {
        selectedMode = .changes
        onChange?(.changes)
    }

    @objc private func selectHistory(_ sender: Any?) {
        selectedMode = .history
        onChange?(.history)
    }
}

/// Left-side repository file tree, Git status, local history, and current-file commit action.
/// Open documents are intentionally left to macOS's native window tabs.
final class DocumentNavigationSidebarView: QuietSidebarBackgroundView,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    static let expandedWidth = DocumentNavigationSidebarWidthPolicy.defaultWidth
    static let collapsedWidth: CGFloat = 0
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
    private let gitModeScopeBar = GitModeScopeBar()
    private let locationLabel = NSTextField(labelWithString: "")
    private let commitCurrentFileButton = NSButton()
    private let separator = QuietSidebarSeparatorView()
    private let resizeHandle = DocumentNavigationResizeHandle()
    private let scrollView = NSScrollView()
    private let tableView = DocumentNavigationTableView()
    private var fileRows: [FileTreeRow] = []
    private var currentFileURL: URL?
    private var fileRootURL: URL?
    private var expandedDirectories = Set<URL>()
    private var gitSnapshot: GitRepositorySnapshot?
    private var displayedGitSnapshot: GitRepositorySnapshot?
    private var currentBufferDiffersFromHEAD: Bool?
    private var mode: DocumentNavigationMode
    private var gitMode: DocumentGitMode
    private var historySnapshot: GitHistorySnapshot?
    private var historyRows: [GitGraphRow] = []
    private var historyTask: Task<Void, Never>?
    private var isLoadingHistory = false
    private var historyLoadFailed = false
    private var commitPopover: NSPopover?
    private var locationBelowModeConstraint: NSLayoutConstraint!
    private var locationBelowGitModeConstraint: NSLayoutConstraint!
    private var modeControlWidthConstraint: NSLayoutConstraint!
    private var gitModeWidthConstraint: NSLayoutConstraint!
    private(set) var preferredExpandedWidth: CGFloat
    private var renameSession: RenameSession?
    private var renameKeyMonitor: RenameKeyMonitorToken?
    private var pendingOpenURL: URL?
    private var scrollBottomConstraint: NSLayoutConstraint!
    private var scrollBottomToCommitConstraint: NSLayoutConstraint!
    private(set) var isExpanded = true

    var onOpenFile: ((URL) -> Void)?
    var onRenameFile: ((URL, String,
                        @escaping @MainActor (Result<URL, Error>) -> Void) -> Void)?
    var canMoveFileToTrash: ((URL) -> Bool)?
    var onMoveFileToTrash: ((URL) -> Void)?
    var onCommitCurrentFile: (() -> Void)?
    var onWidthChange: ((CGFloat, TimeInterval) -> Void)?
    var onModeChange: ((DocumentNavigationMode, DocumentGitMode) -> Void)?

    init(frame frameRect: NSRect,
         mode: DocumentNavigationMode = .files,
         gitMode: DocumentGitMode = .changes) {
        self.mode = mode
        self.gitMode = gitMode
        preferredExpandedWidth = max(frameRect.width,
                                     DocumentNavigationSidebarWidthPolicy.minimumWidth)
        super.init(role: .files)
        frame = frameRect
        autoresizingMask = [.height]

        modeControl.segmentCount = 2
        modeControl.segmentStyle = .capsule
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        gitModeScopeBar.selectedMode = gitMode
        gitModeScopeBar.isHidden = mode != .git
        gitModeScopeBar.onChange = { [weak self] mode in self?.changeGitMode(to: mode) }
        gitModeScopeBar.translatesAutoresizingMaskIntoConstraints = false

        locationLabel.font = .systemFont(ofSize: 11, weight: .medium)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.maximumNumberOfLines = 1
        locationLabel.translatesAutoresizingMaskIntoConstraints = false

        commitCurrentFileButton.bezelStyle = .rounded
        commitCurrentFileButton.controlSize = .small
        commitCurrentFileButton.target = self
        commitCurrentFileButton.action = #selector(commitCurrentFile(_:))
        commitCurrentFileButton.translatesAutoresizingMaskIntoConstraints = false
        commitCurrentFileButton.isHidden = true
        commitCurrentFileButton.setAccessibilityIdentifier("gitCommitCurrentFileButton")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 30
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateSelection(_:))
        tableView.doubleAction = #selector(beginRenameFromDoubleClick(_:))
        tableView.contextMenuForRow = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        tableView.performCommandDelete = { [weak self] in
            self?.moveSelectedFileToTrash() ?? false
        }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        separator.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(modeControl)
        addSubview(gitModeScopeBar)
        addSubview(locationLabel)
        addSubview(scrollView)
        addSubview(commitCurrentFileButton)
        addSubview(resizeHandle)
        scrollBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        scrollBottomToCommitConstraint = scrollView.bottomAnchor.constraint(
            equalTo: commitCurrentFileButton.topAnchor,
            constant: -8
        )
        modeControlWidthConstraint = modeControl.widthAnchor.constraint(
            equalToConstant: preferredExpandedWidth - 28
        )
        gitModeWidthConstraint = gitModeScopeBar.widthAnchor.constraint(
            equalToConstant: preferredExpandedWidth - 40
        )
        locationBelowModeConstraint = locationLabel.topAnchor.constraint(
            equalTo: modeControl.bottomAnchor, constant: 10
        )
        locationBelowGitModeConstraint = locationLabel.topAnchor.constraint(
            equalTo: gitModeScopeBar.bottomAnchor, constant: 7
        )
        NSLayoutConstraint.activate([
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 7),
            modeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            // Keep the segmented control at its expanded width while the sidebar
            // collapses. Compressing NSSegmentedControl to zero makes its segment
            // widths stick in a corrupted arrangement after the sidebar reopens.
            modeControlWidthConstraint,
            modeControl.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            modeControl.heightAnchor.constraint(equalToConstant: 28),
            gitModeScopeBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            gitModeWidthConstraint,
            gitModeScopeBar.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            gitModeScopeBar.heightAnchor.constraint(equalToConstant: 22),
            locationLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            locationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            locationBelowModeConstraint,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: locationLabel.bottomAnchor, constant: 8),
            scrollBottomConstraint,
            commitCurrentFileButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            commitCurrentFileButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            commitCurrentFileButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            commitCurrentFileButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        resizeHandle.currentWidth = { [weak self] in self?.preferredExpandedWidth ?? 0 }
        resizeHandle.onResize = { [weak self] width in self?.resize(to: width) }
        resizeHandle.onReset = { [weak self] in self?.resize(to: Self.expandedWidth) }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage),
                                               name: .appLanguageDidChange, object: nil)
        updateGitModeControlVisibility()
        refreshLanguage()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        historyTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func toggleExpanded() {
        setExpanded(!isExpanded, animated: true)
    }

    func setPreferredExpandedWidth(_ width: CGFloat, notify: Bool = false) {
        let availableWidth = superview?.bounds.width ?? width / 0.45
        let clamped = DocumentNavigationSidebarWidthPolicy.clamp(
            width, containerWidth: availableWidth
        )
        preferredExpandedWidth = clamped
        modeControlWidthConstraint.constant = clamped - 28
        gitModeWidthConstraint.constant = clamped - 40
        if notify, isExpanded { onWidthChange?(clamped, 0) }
    }

    private func resize(to width: CGFloat) {
        setPreferredExpandedWidth(width, notify: true)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard let superview else { return }
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        if !expanded { commitCurrentFileButton.isHidden = true }

        let contentViews: [NSView] = [modeControl, gitModeScopeBar, locationLabel,
                                      scrollView, resizeHandle]
        if isExpanded {
            isHidden = false
            contentViews.forEach {
                $0.isHidden = false
                $0.alphaValue = 0
            }
            gitModeScopeBar.isHidden = mode != .git
        } else {
            // Its frame deliberately stays at the expanded width; hide it before
            // the parent narrows so it cannot draw over the editor during transit.
            modeControl.isHidden = true
            modeControl.alphaValue = 1
        }

        let targetWidth = isExpanded ? preferredExpandedWidth : Self.collapsedWidth
        let duration = animated ? 0.22 : 0
        onWidthChange?(targetWidth, duration)

        guard animated else {
            contentViews.forEach {
                $0.isHidden = !isExpanded
                $0.alphaValue = 1
            }
            if isExpanded { gitModeScopeBar.isHidden = mode != .git }
            isHidden = !isExpanded
            superview.layoutSubtreeIfNeeded()
            refreshCommitAction()
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
        if isExpanded { refreshCommitAction() }
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
        if mode == .git, gitMode == .history,
           historySnapshot?.rootURL.standardizedFileURL != newRoot {
            loadHistory()
        }
        tableView.reloadData()
        selectCurrentRow()
        refreshCommitAction()
    }

    /// Applies the editor's in-memory state to the last repository snapshot.
    /// This deliberately avoids launching Git from the per-edit path.
    func updateCurrentBufferGitState(differsFromHEAD: Bool) {
        guard currentBufferDiffersFromHEAD != differsFromHEAD else { return }
        currentBufferDiffersFromHEAD = differsFromHEAD
        rebuildDisplayedGitSnapshot()
        updateLocationLabel()
        tableView.reloadData()
        refreshCommitAction()
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
            if gitMode == .history {
                if isLoadingHistory {
                    locationLabel.stringValue = AppCopy.text("Loading history…", "正在载入历史…")
                    locationLabel.toolTip = nil
                } else if historyLoadFailed {
                    locationLabel.stringValue = AppCopy.text("History unavailable", "无法载入历史")
                    locationLabel.toolTip = currentFileURL?.path
                } else if let historySnapshot {
                    let branch = historySnapshot.currentBranch ?? AppCopy.text("Detached HEAD", "分离的 HEAD")
                    locationLabel.stringValue = "\(branch) · \(historySnapshot.commits.count)"
                    locationLabel.toolTip = historySnapshot.rootURL.path
                } else {
                    locationLabel.stringValue = AppCopy.text("No Git repository", "未找到 Git 仓库")
                    locationLabel.toolTip = nil
                }
                return
            }
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

    private func refreshCommitAction() {
        let available = mode == .git && currentFileChangeIsCommittable
        commitCurrentFileButton.isHidden = !available || !isExpanded
        scrollBottomConstraint.isActive = !available
        scrollBottomToCommitConstraint.isActive = available
    }

    private var currentFileChangeIsCommittable: Bool {
        guard let currentFileURL,
              MarkdownDirectory.isMarkdown(currentFileURL),
              let snapshot = displayedGitSnapshot else { return false }
        let rootPath = snapshot.rootURL.standardizedFileURL.path
        let filePath = currentFileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return false }
        let relativePath = String(filePath.dropFirst(rootPath.count + 1))
        guard let change = snapshot.changes.first(where: { $0.path == relativePath }) else {
            return false
        }
        return !change.isIgnored
            && change.pathState != .conflicted
            && change.indexStatus != "D"
            && change.workTreeStatus != "D"
            && change.indexStatus != "R"
            && change.workTreeStatus != "R"
            && change.indexStatus != "C"
            && change.workTreeStatus != "C"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch mode {
        case .files: fileRows.count
        case .git:
            gitMode == .changes
                ? displayedGitSnapshot?.changes.count ?? 0
                : historySnapshot?.commits.count ?? 0
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
            if gitMode == .history {
                guard let snapshot = historySnapshot,
                      snapshot.commits.indices.contains(row),
                      historyRows.indices.contains(row) else { return nil }
                let id = NSUserInterfaceItemIdentifier("GitHistoryCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: self)
                            as? GitHistoryCellView) ?? {
                    let cell = GitHistoryCellView()
                    cell.identifier = id
                    return cell
                }()
                let commit = snapshot.commits[row]
                cell.configure(
                    commit: commit,
                    row: historyRows[row],
                    isHEAD: commit.id == snapshot.headID
                )
                return cell
            }
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
        commitCurrentFileButton.title = AppCopy.text(
            "Commit Current File…",
            "提交当前文件…"
        )
        commitCurrentFileButton.toolTip = AppCopy.text(
            "Save and commit only the current Markdown file",
            "保存并只提交当前 Markdown 文件"
        )
        modeControl.setAccessibilityLabel(AppCopy.text("Sidebar mode", "侧栏模式"))
        gitModeScopeBar.refreshLanguage()
        updateLocationLabel()
        if renameSession == nil { tableView.reloadData() }
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .git : .files
        updateGitModeControlVisibility()
        if mode == .git, let currentFileURL {
            gitSnapshot = GitRepository.snapshot(containing: currentFileURL)
            rebuildDisplayedGitSnapshot()
            if gitMode == .history { loadHistory() }
        }
        updateLocationLabel()
        tableView.reloadData()
        selectCurrentRow()
        refreshCommitAction()
        onModeChange?(mode, gitMode)
    }

    @objc private func commitCurrentFile(_ sender: Any?) {
        onCommitCurrentFile?()
    }

    private func changeGitMode(to newMode: DocumentGitMode) {
        gitMode = newMode
        commitPopover?.close()
        if gitMode == .history { loadHistory() }
        updateLocationLabel()
        tableView.reloadData()
        selectCurrentRow()
        onModeChange?(mode, gitMode)
    }

    private func updateGitModeControlVisibility() {
        let showsGitModes = mode == .git
        gitModeScopeBar.isHidden = !showsGitModes
        locationBelowModeConstraint.isActive = !showsGitModes
        locationBelowGitModeConstraint.isActive = showsGitModes
    }

    private func loadHistory() {
        historyTask?.cancel()
        guard let currentFileURL else {
            historySnapshot = nil
            historyRows = []
            isLoadingHistory = false
            historyLoadFailed = false
            updateLocationLabel()
            tableView.reloadData()
            return
        }
        isLoadingHistory = true
        historyLoadFailed = false
        updateLocationLabel()
        tableView.reloadData()
        historyTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                GitRepository.history(containing: currentFileURL)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.historySnapshot = snapshot
            self.historyRows = snapshot.map { GitGraphLayout.rows(for: $0.commits) } ?? []
            self.isLoadingHistory = false
            self.historyLoadFailed = snapshot == nil
            self.updateLocationLabel()
            self.tableView.reloadData()
        }
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
            if gitMode == .history {
                if commitPopover?.isShown != true { showCommitDetails(at: row) }
                return
            }
            guard let snapshot = displayedGitSnapshot,
                  snapshot.changes.indices.contains(row) else { return }
            let url = snapshot.rootURL.appendingPathComponent(snapshot.changes[row].path)
            if MarkdownDirectory.isMarkdown(url) { onOpenFile?(url) }
        }
    }

    private func showCommitDetails(at row: Int) {
        guard let snapshot = historySnapshot,
              snapshot.commits.indices.contains(row) else { return }
        let commit = snapshot.commits[row]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = GitCommitDetailViewController(
            commit: commit,
            isHEAD: commit.id == snapshot.headID
        )
        commitPopover?.close()
        commitPopover = popover
        let rowRect = tableView.rect(ofRow: row)
        popover.show(relativeTo: rowRect, of: tableView, preferredEdge: .maxX)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        mode == .git && gitMode == .history ? 45 : 30
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard mode == .git, gitMode == .history,
              tableView.selectedRow >= 0 else { return }
        showCommitDetails(at: tableView.selectedRow)
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

    private func contextMenu(forRow row: Int) -> NSMenu? {
        cancelPendingOpen()
        guard mode == .files,
              renameSession == nil,
              fileRows.indices.contains(row) else { return nil }
        let entry = fileRows[row].entry
        let canTrash = !entry.isDirectory && (canMoveFileToTrash?(entry.url) ?? false)
        let kind: DocumentSidebarEntryKind = entry.isDirectory ? .directory : .markdownFile
        let commands = DocumentSidebarContextMenuPolicy.commands(
            for: kind,
            canMoveToTrash: canTrash
        )
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in commands {
            if command == .moveToTrash { menu.addItem(.separator()) }
            menu.addItem(contextMenuItem(for: command, url: entry.url))
        }
        return menu
    }

    private func contextMenuItem(for command: DocumentSidebarContextCommand,
                                 url: URL) -> NSMenuItem {
        let configuration: (String, String, Selector) = switch command {
        case .open:
            (AppCopy.text("Open", "打开"), "doc.text", #selector(openContextFile(_:)))
        case .rename:
            (AppCopy.text("Rename", "重命名"), "pencil", #selector(renameContextFile(_:)))
        case .showInFinder:
            (AppCopy.text("Show in Finder", "在 Finder 中显示"),
             "folder", #selector(showContextFileInFinder(_:)))
        case .copyPath:
            (AppCopy.text("Copy Path", "复制路径"),
             "doc.on.doc", #selector(copyContextFilePath(_:)))
        case .moveToTrash:
            (AppCopy.text("Move to Trash", "移到废纸篓"),
             "trash", #selector(moveContextFileToTrash(_:)))
        }
        let item = NSMenuItem(
            title: configuration.0,
            action: configuration.2,
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = url.standardizedFileURL
        item.image = NSImage(
            systemSymbolName: configuration.1,
            accessibilityDescription: configuration.0
        )
        return item
    }

    @objc private func openContextFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenFile?(url)
    }

    @objc private func renameContextFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let row = fileRows.firstIndex(where: {
                  $0.entry.url.standardizedFileURL == url.standardizedFileURL
              }),
              !fileRows[row].entry.isDirectory,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? QuietSidebarCellView,
              let field = cell.textField else { return }
        beginRename(url, field: field, cell: cell)
    }

    @objc private func showContextFileInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyContextFilePath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    @objc private func moveContextFileToTrash(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onMoveFileToTrash?(url)
    }

    private func moveSelectedFileToTrash() -> Bool {
        guard mode == .files,
              renameSession == nil,
              fileRows.indices.contains(tableView.selectedRow) else { return false }
        let entry = fileRows[tableView.selectedRow].entry
        guard !entry.isDirectory,
              canMoveFileToTrash?(entry.url) == true else { return false }
        onMoveFileToTrash?(entry.url)
        return true
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

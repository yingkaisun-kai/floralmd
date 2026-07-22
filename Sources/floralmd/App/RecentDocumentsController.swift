import AppKit

@MainActor
final class RecentDocumentsController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSWindowDelegate {

    private let tableView = RecentDocumentsTableView()
    private var urls: [URL] = []
    private weak var sourceDocument: Document?
    private weak var previousKeyWindow: NSWindow?

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.hidesOnDeactivate = true
        self.init(window: panel)
        panel.delegate = self
        buildContent()
    }

    func show(urls: [URL], from sourceDocument: Document?) {
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }

        self.urls = urls
        self.sourceDocument = sourceDocument
        if window?.isVisible != true {
            previousKeyWindow = NSApp.keyWindow
        }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        positionWindow(over: previousKeyWindow)

        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(tableView)
    }

    private func buildContent() {
        guard let window else { return }

        let title = NSTextField(labelWithString: AppCopy.text("Open Recent", "最近打开"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitle = NSTextField(labelWithString: AppCopy.text(
            "Choose a file to open in the current tab group.",
            "选择要在当前标签组中打开的文件。"
        ))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recentDocument"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 54
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedDocument)
        tableView.onConfirm = { [weak self] in self?.openSelectedDocument() }
        tableView.onCancel = { [weak self] in self?.closeChooser() }
        tableView.setAccessibilityLabel(AppCopy.text("Recent files", "最近文件"))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let stack = NSStackView(views: [heading, scrollView])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        urls.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard urls.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("RecentDocumentCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? RecentDocumentCellView ?? RecentDocumentCellView()
        cell.identifier = identifier
        cell.configure(with: urls[row])
        return cell
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.orderOut(nil)
    }

    @objc private func openSelectedDocument() {
        let row = tableView.selectedRow
        guard urls.indices.contains(row),
              let controller = NSDocumentController.shared as? DocumentController else {
            NSSound.beep()
            return
        }
        let url = urls[row]
        let source = sourceDocument
        closeChooser()
        DispatchQueue.main.async {
            controller.openRecentDocument(at: url, from: source)
        }
    }

    private func closeChooser() {
        window?.orderOut(nil)
        previousKeyWindow?.makeKeyAndOrderFront(nil)
    }

    private func positionWindow(over sourceWindow: NSWindow?) {
        guard let window else { return }
        guard let sourceWindow else {
            window.center()
            return
        }

        let size = window.frame.size
        let proposed = NSPoint(
            x: sourceWindow.frame.midX - size.width / 2,
            y: sourceWindow.frame.midY - size.height / 2
        )
        let visibleFrame = sourceWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let visibleFrame else {
            window.setFrameOrigin(proposed)
            return
        }
        let origin = NSPoint(
            x: min(max(proposed.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposed.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        window.setFrameOrigin(origin)
    }
}

@MainActor
private final class RecentDocumentsTableView: NSTableView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onConfirm?()
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class RecentDocumentCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let pathField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleField.font = .systemFont(ofSize: 14, weight: .medium)
        titleField.lineBreakMode = .byTruncatingMiddle
        pathField.font = .systemFont(ofSize: 11)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle

        let labels = NSStackView(views: [titleField, pathField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with url: URL) {
        titleField.stringValue = url.lastPathComponent
        pathField.stringValue = abbreviatedPath(url.deletingLastPathComponent().path)
        setAccessibilityLabel("\(url.lastPathComponent), \(url.path)")
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

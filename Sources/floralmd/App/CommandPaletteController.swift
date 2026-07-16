import AppKit
import FloralMDCore

@MainActor
final class CommandPaletteController: NSWindowController,
    NSSearchFieldDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSWindowDelegate {

    fileprivate struct Entry {
        let definition: ShortcutCommandDefinition
        let title: String
        let category: String
        let shortcut: String
        let isEnabled: Bool
        let searchText: String
    }

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var allEntries: [Entry] = []
    private var visibleEntries: [Entry] = []
    private weak var previousKeyWindow: NSWindow?

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 430),
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

    func show() {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(searchField)
            return
        }
        previousKeyWindow = NSApp.keyWindow
        assert(
            ShortcutCatalog.definitions
                .filter(\.appearsInCommandPalette)
                .allSatisfy { CommandDispatcher.supports($0.id) },
            "Every command-palette entry must have a dispatcher mapping"
        )
        allEntries = ShortcutCatalog.definitions.compactMap(makeEntry)
        searchField.stringValue = ""
        filterEntries()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
    }

    private func buildContent() {
        guard let window else { return }

        searchField.placeholderString = AppCopy.text("Search commands", "搜索命令")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(AppCopy.text("Command search", "命令搜索"))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(runSelectedCommand)
        tableView.setAccessibilityLabel(AppCopy.text("Command results", "命令结果"))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let stack = NSStackView(views: [searchField, scrollView])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 28),
        ])
        window.contentView = content
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CommandPaletteCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? CommandPaletteCellView ?? CommandPaletteCellView()
        cell.identifier = identifier
        cell.configure(with: visibleEntries[row])
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        filterEntries()
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            runSelectedCommand()
        case #selector(NSResponder.cancelOperation(_:)):
            closePalette()
        default:
            return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.orderOut(nil)
    }

    private func makeEntry(_ definition: ShortcutCommandDefinition) -> Entry? {
        guard definition.appearsInCommandPalette else { return nil }
        let title = AppCopy.text(definition.englishTitle, definition.chineseTitle)
        let category = categoryTitle(definition.category)
        let shortcut = AppSettings.effectiveShortcut(for: definition.id)
            .map(ShortcutManager.displayName(for:)) ?? ""
        let searchText = [
            definition.englishTitle,
            definition.chineseTitle,
            definition.id,
            category,
            shortcut,
        ].joined(separator: " ").folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return Entry(
            definition: definition,
            title: title,
            category: category,
            shortcut: shortcut,
            isEnabled: CommandDispatcher.canExecute(definition.id),
            searchText: searchText
        )
    }

    private func filterEntries() {
        let query = searchField.stringValue.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        visibleEntries = tokens.isEmpty
            ? allEntries
            : allEntries.filter { entry in
                tokens.allSatisfy(entry.searchText.contains)
            }
        tableView.reloadData()
        if let firstEnabled = visibleEntries.firstIndex(where: \.isEnabled) {
            tableView.selectRowIndexes(IndexSet(integer: firstEnabled), byExtendingSelection: false)
            tableView.scrollRowToVisible(firstEnabled)
        } else {
            tableView.deselectAll(nil)
        }
        tableView.setAccessibilityValue(
            AppCopy.text(
                "\(visibleEntries.count) command results",
                "\(visibleEntries.count) 个命令结果"
            )
        )
    }

    private func moveSelection(by offset: Int) {
        guard !visibleEntries.isEmpty else { return }
        var row = tableView.selectedRow
        if row < 0 { row = offset > 0 ? -1 : visibleEntries.count }
        for _ in visibleEntries.indices {
            row += offset
            guard visibleEntries.indices.contains(row) else { return }
            if visibleEntries[row].isEnabled {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
                return
            }
        }
    }

    @objc private func runSelectedCommand() {
        let row = tableView.selectedRow
        guard visibleEntries.indices.contains(row),
              visibleEntries[row].isEnabled else {
            NSSound.beep()
            return
        }
        let commandID = visibleEntries[row].definition.id
        closePalette()
        DispatchQueue.main.async {
            CommandDispatcher.execute(commandID)
        }
    }

    private func closePalette() {
        window?.orderOut(nil)
        previousKeyWindow?.makeKeyAndOrderFront(nil)
    }

    private func categoryTitle(_ category: ShortcutCommandDefinition.Category) -> String {
        switch category {
        case .application: return AppCopy.text("Application", "应用")
        case .file: return AppCopy.text("File", "文件")
        case .edit: return AppCopy.text("Edit", "编辑")
        case .view: return AppCopy.text("View", "视图")
        case .format: return AppCopy.text("Format", "格式")
        case .window: return AppCopy.text("Window", "窗口")
        case .global: return AppCopy.text("Global", "全局")
        }
    }
}

@MainActor
private final class CommandPaletteCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        shortcutField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.alignment = .right

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.spacing = 1
        labels.alignment = .leading

        let row = NSStackView(views: [labels, shortcutField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutField.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with entry: CommandPaletteController.Entry) {
        titleField.stringValue = entry.title
        detailField.stringValue = "\(entry.category) · \(entry.definition.id)"
        shortcutField.stringValue = entry.shortcut
        let primaryColor: NSColor = entry.isEnabled ? .labelColor : .disabledControlTextColor
        let secondaryColor: NSColor = entry.isEnabled
            ? .secondaryLabelColor
            : .disabledControlTextColor
        titleField.textColor = primaryColor
        detailField.textColor = secondaryColor
        shortcutField.textColor = secondaryColor
        setAccessibilityLabel(
            [entry.title, entry.category, entry.shortcut]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
        setAccessibilityEnabled(entry.isEnabled)
    }
}

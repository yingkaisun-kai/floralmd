// SettingsWindowController — the Settings window.
//
// The window uses an AppKit split-view shell so navigation remains fixed while
// each existing SwiftUI settings pane keeps ownership of its bindings and
// side effects. Pane hosting controllers are cached: switching sections does
// not reset transient state such as shortcut search or an open sheet.

import AppKit
import FloralMDCore
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let contentController = SettingsContainerViewController()
        let window = NSWindow(contentViewController: contentController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = AppCopy.text("Settings", "设置")
        window.setContentSize(NSSize(
            width: SettingsWindowLayout.defaultWidth,
            height: SettingsWindowLayout.defaultHeight
        ))
        window.minSize = NSSize(
            width: SettingsWindowLayout.minimumWidth,
            height: SettingsWindowLayout.minimumHeight
        )
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

private extension SettingsPaneID {
    var label: String {
        switch self {
        case .general: AppCopy.text("General", "通用")
        case .editor: AppCopy.text("Editor", "编辑器")
        case .shortcuts: AppCopy.text("Shortcuts", "快捷键")
        case .appearance: AppCopy.text("Appearance", "外观")
        case .advanced: AppCopy.text("Advanced", "高级")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .editor: "text.cursor"
        case .shortcuts: "keyboard"
        case .appearance: "eyeglasses"
        case .advanced: "gearshape.2"
        }
    }
}

private final class SettingsContainerViewController: NSSplitViewController {
    private let sidebarController = SettingsSidebarViewController()
    private let detailController = SettingsDetailViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = SettingsWindowLayout.minimumSidebarWidth
        sidebarItem.maximumThickness = SettingsWindowLayout.maximumSidebarWidth
        sidebarItem.preferredThicknessFraction = 0.22
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = SettingsWindowLayout.minimumDetailWidth
        addSplitViewItem(detailItem)

        sidebarController.onSelection = { [weak self] pane in
            self?.detailController.show(pane)
        }
        sidebarController.select(.general)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLanguage),
            name: .appLanguageDidChange,
            object: nil
        )
    }

    @objc private func refreshLanguage() {
        sidebarController.refreshLanguage()
        view.window?.title = AppCopy.text("Settings", "设置")
    }
}

private final class SettingsSidebarViewController: NSViewController,
                                                   NSTableViewDataSource,
                                                   NSTableViewDelegate {
    var onSelection: ((SettingsPaneID) -> Void)?

    private let tableView = NSTableView()
    private let panes = SettingsPaneID.allCases

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settingsPane"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.style = .sourceList
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(AppCopy.text("Settings sections", "设置分区"))
        scrollView.documentView = tableView

        view = scrollView
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        panes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let pane = panes[row]
        let identifier = NSUserInterfaceItemIdentifier("SettingsSidebarCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = pane.label
        cell.imageView?.image = NSImage(
            systemSymbolName: pane.symbol,
            accessibilityDescription: pane.label
        )
        cell.setAccessibilityLabel(pane.label)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard panes.indices.contains(tableView.selectedRow) else { return }
        onSelection?(panes[tableView.selectedRow])
    }

    func select(_ pane: SettingsPaneID) {
        guard let row = panes.firstIndex(of: pane) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        onSelection?(pane)
    }

    func refreshLanguage() {
        tableView.setAccessibilityLabel(AppCopy.text("Settings sections", "设置分区"))
        tableView.reloadData()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        cell.imageView = imageView
        cell.addSubview(imageView)

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        cell.textField = textField
        cell.addSubview(textField)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

private final class SettingsDetailViewController: NSViewController {
    /// Owns the editor font / line-height state and the font-panel plumbing.
    private let fonts = FontSettings()
    private lazy var controllers: [SettingsPaneID: NSViewController] = [
        .general: NSHostingController(rootView: GeneralSettingsView()),
        .editor: NSHostingController(rootView: EditorSettingsView()),
        .shortcuts: NSHostingController(rootView: ShortcutsSettingsView()),
        .appearance: NSHostingController(rootView: AppearanceSettingsView(fonts: fonts)),
        .advanced: NSHostingController(rootView: AdvancedSettingsView()),
    ]
    private weak var visibleController: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func show(_ pane: SettingsPaneID) {
        guard let controller = controllers[pane], controller !== visibleController else { return }
        visibleController?.view.removeFromSuperview()
        visibleController?.removeFromParent()

        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        visibleController = controller
    }
}

// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit
import FloralMDCore

// MARK: - View menu

@MainActor
enum ViewMenu {

    /// The top-level "View" menu item (with its submenu).
    static func build() -> NSMenuItem {
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: AppCopy.text("View", "视图"))

        // Routes through the responder chain to the key window's toolbar.
        // AppKit auto-inserts "Show Tab Bar"/"Show All Tabs" above this at
        // runtime (window tabbing is on by default) — that position isn't
        // ours to control short of disabling tabbing outright.
        viewMenu.addItem(withTitle: AppCopy.text("Customize Toolbar…", "自定义工具栏…"),
                         action: #selector(NSWindow.runToolbarCustomizationPalette(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(.separator())

        viewMenu.addItem(MenuCommand(
            id: "view.toggleOutlineSidebar",
            title: AppCopy.text("Toggle Outline Sidebar", "切换大纲侧栏"),
            action: #selector(Document.toggleOutlineSidebar(_:))
        ).makeItem())
        viewMenu.addItem(MenuCommand(
            id: "view.toggleNavigationSidebar",
            title: AppCopy.text("Toggle File Sidebar", "切换文件侧栏"),
            action: #selector(Document.toggleNavigationSidebar(_:))
        ).makeItem())

        let minimapItem = viewMenu.addItem(
            withTitle: AppCopy.text("Show Minimap", "显示缩略图"),
            action: #selector(AppDelegate.toggleMinimap(_:)),
            keyEquivalent: "")
        minimapItem.state = AppSettings.showMinimap ? .on : .off
        ShortcutManager.configure(minimapItem, commandID: "view.toggleMinimap")

        let typewriterItem = viewMenu.addItem(
            withTitle: AppCopy.text("Typewriter Scroll", "打字机滚动"),
            action: #selector(AppDelegate.toggleTypewriterMode(_:)),
            keyEquivalent: "")
        ShortcutManager.configure(typewriterItem, commandID: "view.toggleTypewriter")
        typewriterItem.state = AppSettings.typewriterMode ? .on : .off

        // View-mode toggle (Edit ↔ Read) + the Source-mode checkbox.
        viewMenu.addItem(.separator())
        viewMenu.addItem(FormatMenu.viewModeToggleItem())
        let sourceItem = viewMenu.addItem(withTitle: AppCopy.text("Show Source in Editor", "在编辑器中显示源码"),
                                          action: #selector(AppDelegate.toggleSourceMode(_:)),
                                          keyEquivalent: "")
        ShortcutManager.configure(sourceItem, commandID: "view.toggleSource")
        sourceItem.state = AppSettings.sourceMode ? .on : .off
        viewMenu.addItem(.separator())

        let fullScreen = viewMenu.addItem(
            withTitle: AppCopy.text("Enter Full Screen", "进入全屏"),
            action: #selector(AppDelegate.toggleDocumentFullScreen(_:)),
            keyEquivalent: ""
        )
        fullScreen.target = NSApp.delegate
        ShortcutManager.configure(fullScreen, commandID: "view.toggleFullScreen")
        viewMenu.addItem(.separator())

        // Zoom (font size + max content width, scaled together). Target nil
        // routes through the responder chain to the key window's Document.
        let actualSize = viewMenu.addItem(withTitle: AppCopy.text("Actual Size", "实际大小"),
                                          action: #selector(Document.actualSize(_:)),
                                          keyEquivalent: "")
        ShortcutManager.configure(actualSize, commandID: "view.actualSize")
        let zoomIn = viewMenu.addItem(withTitle: AppCopy.text("Zoom In", "放大"),
                                      action: #selector(Document.zoomIn(_:)),
                                      keyEquivalent: "")
        ShortcutManager.configure(zoomIn, commandID: "view.zoomIn")
        let zoomOut = viewMenu.addItem(withTitle: AppCopy.text("Zoom Out", "缩小"),
                                       action: #selector(Document.zoomOut(_:)),
                                       keyEquivalent: "")
        ShortcutManager.configure(zoomOut, commandID: "view.zoomOut")

        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }
}

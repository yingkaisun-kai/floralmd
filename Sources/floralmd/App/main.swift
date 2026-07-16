import AppKit
import Carbon.HIToolbox
import FloralMDCore
#if FLORALMD_PRODUCTION
import Sparkle
#endif

// The bundle layer selects either the production FloralMD identity or the fully
// isolated FloralMD-Debug identity. The SwiftPM target stays `floralmd`; the build
// script gives the copied Debug executable its explicit `floralmd-debug` name.

// --- App Delegate -----------------------------------------------------------

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    var aboutWindowController: AboutWindowController?
    var settingsWindowController: SettingsWindowController?
    private var commandPaletteController: CommandPaletteController?
    private let memoryWatchdog = MemoryWatchdog()
    private let globalHotKeyController = GlobalHotKeyController()
    private var lastGlobalHotKeyError: OSStatus?
    #if FLORALMD_PRODUCTION
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.migrateShortcutSettingsIfNeeded()
        AppSettings.applyLogging()
        AppSettings.applyDocumentSaving()
        memoryWatchdog.start()
        Log.info("\(AppIdentity.displayName) launched", category: .app)
        AppSettings.applyAppearance()
        setupMenuBar()
        NotificationCenter.default.addObserver(self, selector: #selector(appLanguageChanged),
                                               name: .appLanguageDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickCaptureSettingsDidChange),
            name: .quickCaptureSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutSettingsDidChange),
            name: .shortcutSettingsDidChange,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(keyboardInputSourceDidChange),
            name: Notification.Name(
                kTISNotifySelectedKeyboardInputSourceChanged as String
            ),
            object: nil
        )
        globalHotKeyController.onPressed = { [weak self] in
            self?.performQuickCapture(nil)
        }
        configureGlobalQuickCaptureShortcut()

        // Opt-in (default off): upload any crash reports macOS wrote for us since
        // last launch. Fire-and-forget; never blocks startup.
        if AppSettings.sendCrashLogs {
            CrashReporter.uploadPendingReports(
                alreadySent: AppSettings.sentCrashReports,
                onSent: { AppSettings.sentCrashReports.insert($0) })
        }

        // Open file from command-line argument. When a file is given,
        // `applicationShouldOpenUntitledFile` suppresses the otherwise-automatic
        // blank document, so we don't end up with two windows.
        let args = CommandLine.arguments
        if args.count > 1 {
            let url = URL(fileURLWithPath: args[1])
            Log.info("Opening file from launch argument: \(url.path)", category: .document)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }

        #if DEBUG
        ReproScript.runIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        memoryWatchdog.stop()
    }

    // Auto-open a blank document on launch only when no file was passed on the
    // command line (otherwise the file arg + the blank doc make two windows).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        ApplicationLifecyclePolicy.shouldOpenUntitledFileAtLaunch(
            hasExplicitFileRequest: CommandLine.arguments.count > 1,
            startupCreatesNewDocument: AppSettings.startupAction == .createNewDocument
        )
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        AppSettings.reopenWindows
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.quickCaptureEnabled
    }

    // AppKit's documented `true` path already creates one untitled document
    // when a document app is reopened without visible windows. Never also call
    // `newDocument` here: that gives one Dock activation two creation owners.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ApplicationLifecyclePolicy.reopenHandling(
            hasVisibleWindows: flag,
            startupCreatesNewDocument: AppSettings.startupAction == .createNewDocument
        ) == .appKitDefault
    }

    // MARK: - Settings

    @MainActor @objc func showAbout(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @MainActor @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @MainActor @objc func showCommandPalette(_ sender: Any?) {
        if commandPaletteController == nil {
            commandPaletteController = CommandPaletteController()
        }
        commandPaletteController?.show()
    }

    @MainActor @objc func checkForUpdates(_ sender: Any?) {
        #if FLORALMD_PRODUCTION
        updaterController.checkForUpdates(sender)
        #endif
    }

    // MARK: - Quick Capture

    @MainActor @objc func performQuickCapture(_ sender: Any?) {
        guard AppSettings.quickCaptureEnabled else {
            showSettings(sender)
            return
        }
        guard AppSettings.autoSaveUntitledDocuments,
              AppSettings.untitledDocumentDirectoryURL() != nil else {
            showSettings(sender)
            let alert = NSAlert()
            alert.messageText = AppCopy.text(
                "Choose a Quick Capture Folder",
                "选择快速记录文件夹"
            )
            alert.informativeText = AppCopy.text(
                "Quick Capture saves each note as a Markdown file. Choose its folder in General settings.",
                "快速记录会把每条内容保存为 Markdown 文件。请在通用设置中选择目标文件夹。"
            )
            alert.runModal()
            return
        }

        let controller = NSDocumentController.shared
        if let reusable = controller.documents.reversed().compactMap({ $0 as? Document }).first(where: {
            $0.windowControllers.first?.window != nil
                && QuickCapturePolicy.shouldReuseWindow(
                    isQuickCapture: $0.isQuickCapture,
                    hasFileURL: $0.fileURL != nil,
                    rawSource: $0.editor?.rawSource ?? ""
                )
        }) {
            reusable.activateAsQuickCapture()
            return
        }

        do {
            // Mark the document as Quick Capture before its window is built, so
            // it never flashes the normal saved size or expanded sidebars.
            guard let document = try controller.openUntitledDocumentAndDisplay(false) as? Document else {
                return
            }
            document.activateAsQuickCapture()
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    @MainActor @objc func toggleDocumentAlwaysOnTop(_ sender: Any?) {
        activeDocument?.toggleAlwaysOnTop(sender)
    }

    @MainActor @objc func toggleDocumentAlwaysOnTopAcrossSpaces(_ sender: Any?) {
        activeDocument?.toggleAlwaysOnTopAcrossSpaces(sender)
    }

    @MainActor @objc func toggleDocumentFullScreen(_ sender: Any?) {
        activeDocument?.windowControllers.first?.window?.toggleFullScreen(sender)
    }

    private var activeDocument: Document? {
        guard let window = NSApp.keyWindow else { return nil }
        return NSDocumentController.shared.document(for: window) as? Document
    }

    @objc private func quickCaptureSettingsDidChange() {
        configureGlobalQuickCaptureShortcut()
    }

    @objc private func shortcutSettingsDidChange() {
        setupMenuBar()
        configureGlobalQuickCaptureShortcut()
        for case let document as Document in NSDocumentController.shared.documents {
            document.refreshShortcutPresentation()
        }
    }

    @objc private func keyboardInputSourceDidChange() {
        NotificationCenter.default.post(name: .keyboardInputSourceDidChange, object: nil)
    }

    private func configureGlobalQuickCaptureShortcut() {
        let shortcut = AppSettings.quickCaptureShortcut
        let previousShortcut = globalHotKeyController.registeredShortcut
        let status = globalHotKeyController.update(
            enabled: AppSettings.quickCaptureEnabled,
            shortcut: shortcut
        )
        guard status != noErr else {
            lastGlobalHotKeyError = nil
            return
        }
        Log.error(
            "Could not register Quick Capture shortcut \(shortcut.map(ShortcutManager.displayName(for:)) ?? "None"): OSStatus \(status)",
            category: .app
        )
        if let previousShortcut {
            AppSettings.setShortcutOverride(
                .shortcut(previousShortcut),
                for: "file.quickCapture"
            )
        } else {
            AppSettings.quickCaptureEnabled = false
        }
        guard lastGlobalHotKeyError != status else { return }
        lastGlobalHotKeyError = status
        let alert = NSAlert()
        alert.messageText = AppCopy.text(
            "Quick Capture Shortcut Unavailable",
            "快速记录快捷键不可用"
        )
        alert.informativeText = AppCopy.text(
            "\(shortcut.map(ShortcutManager.displayName(for:)) ?? "") is already used by macOS or another app. Choose a different shortcut in Shortcuts settings.",
            "\(shortcut.map(ShortcutManager.displayName(for:)) ?? "") 已被 macOS 或其他应用占用。请在快捷键设置中选择其他快捷键。"
        )
        alert.runModal()
    }

    // MARK: - View

    @MainActor @objc func toggleTypewriterMode(_ sender: Any?) {
        EditorPreferenceCoordinator.setTypewriterMode(!AppSettings.typewriterMode)
    }

    @MainActor @objc func toggleSourceMode(_ sender: Any?) {
        EditorPreferenceCoordinator.setSourceMode(!AppSettings.sourceMode)
    }

    @MainActor @objc func toggleMinimap(_ sender: Any?) {
        EditorPreferenceCoordinator.setShowMinimap(!AppSettings.showMinimap)
    }

    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleTypewriterMode(_:)):
            menuItem.state = AppSettings.typewriterMode ? .on : .off
        case #selector(toggleSourceMode(_:)):
            menuItem.state = AppSettings.sourceMode ? .on : .off
        case #selector(toggleMinimap(_:)):
            menuItem.state = AppSettings.showMinimap ? .on : .off
        case #selector(toggleDocumentAlwaysOnTop(_:)):
            guard let document = activeDocument else {
                menuItem.state = .off
                return false
            }
            menuItem.state = document.windowPinningMode == .currentSpace ? .on : .off
        case #selector(toggleDocumentAlwaysOnTopAcrossSpaces(_:)):
            guard let document = activeDocument else {
                menuItem.state = .off
                return false
            }
            menuItem.state = document.windowPinningMode == .allSpaces ? .on : .off
        case #selector(toggleDocumentFullScreen(_:)):
            guard let window = activeDocument?.windowControllers.first?.window else {
                return false
            }
            menuItem.title = window.styleMask.contains(.fullScreen)
                ? AppCopy.text("Exit Full Screen", "退出全屏")
                : AppCopy.text("Enter Full Screen", "进入全屏")
        default:
            break
        }
        return true
    }

    // MARK: - Open Document

    /// Manual Open panel — bypasses NSDocumentController's type validation
    /// which is broken without Info.plist.
    @MainActor @objc func openDocumentManually(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            NSDocumentController.shared.openDocument(
                withContentsOf: url, display: true
            ) { _, _, error in
                if let error = error {
                    NSAlert(error: error).runModal()
                }
            }
        }

        // Attach the panel to the front window as a sheet so it's always visible
        // — a free-floating panel can open off-screen or behind the window
        // (the app's windows can launch off-screen), which looks like a hang.
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            panel.begin(completionHandler: complete)
        }
    }

    // MARK: - Menu Bar

    @objc private func appLanguageChanged() {
        setupMenuBar()
        for case let document as Document in NSDocumentController.shared.documents {
            document.refreshLocalizedInterface()
        }
    }

    @MainActor private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu (required for Cmd+Q)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = AppIdentity.displayName
        appMenu.addItem(withTitle: AppCopy.text("About \(appName)", "关于 \(appName)"),
                        action: #selector(AppDelegate.showAbout(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settings = appMenu.addItem(withTitle: AppCopy.text("Settings…", "设置…"),
                                       action: #selector(AppDelegate.showSettings(_:)),
                                       keyEquivalent: "")
        ShortcutManager.configure(settings, commandID: "app.settings")
        let commandPalette = appMenu.addItem(
            withTitle: AppCopy.text("Command Palette…", "命令面板…"),
            action: #selector(AppDelegate.showCommandPalette(_:)),
            keyEquivalent: ""
        )
        ShortcutManager.configure(commandPalette, commandID: "app.commandPalette")

        #if FLORALMD_PRODUCTION
        let checkForUpdates = appMenu.addItem(
            withTitle: AppCopy.text("Check for Updates…", "检查更新…"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        ShortcutManager.configure(checkForUpdates, commandID: "app.checkUpdates")
        #endif

        appMenu.addItem(NSMenuItem.separator())

        let hide = appMenu.addItem(withTitle: AppCopy.text("Hide \(appName)", "隐藏 \(appName)"),
                                   action: #selector(NSApplication.hide(_:)), keyEquivalent: "")
        ShortcutManager.configure(hide, commandID: "app.hide")
        let hideOthers = appMenu.addItem(withTitle: AppCopy.text("Hide Others", "隐藏其他应用"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "")
        ShortcutManager.configure(hideOthers, commandID: "app.hideOthers")
        appMenu.addItem(withTitle: AppCopy.text("Show All", "显示全部"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        appMenu.addItem(NSMenuItem.separator())

        let quit = appMenu.addItem(withTitle: AppCopy.text("Quit \(appName)", "退出 \(appName)"),
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "")
        ShortcutManager.configure(quit, commandID: "app.quit")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu — NSDocument provides the standard actions
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: AppCopy.text("File", "文件"))

        let newDocument = fileMenu.addItem(withTitle: AppCopy.text("New", "新建"),
                                           action: #selector(NSDocumentController.newDocument(_:)),
                                           keyEquivalent: "")
        ShortcutManager.configure(newDocument, commandID: "file.new")

        let quickCapture = fileMenu.addItem(
            withTitle: AppCopy.text("New Quick Capture", "新建快速记录"),
            action: #selector(AppDelegate.performQuickCapture(_:)),
            keyEquivalent: ""
        )
        quickCapture.target = self
        ShortcutManager.configure(quickCapture, commandID: "file.quickCapture")

        let open = fileMenu.addItem(withTitle: AppCopy.text("Open…", "打开…"),
                                    action: #selector(AppDelegate.openDocumentManually(_:)),
                                    keyEquivalent: "")
        ShortcutManager.configure(open, commandID: "file.open")

        // Recent documents submenu
        let recentMenuItem = NSMenuItem(title: AppCopy.text("Open Recent", "最近打开"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: AppCopy.text("Open Recent", "最近打开"))
        recentMenu.addItem(withTitle: AppCopy.text("Clear Menu", "清除菜单"),
                           action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                           keyEquivalent: "")
        recentMenuItem.submenu = recentMenu
        fileMenu.addItem(recentMenuItem)

        fileMenu.addItem(NSMenuItem.separator())

        let save = fileMenu.addItem(withTitle: AppCopy.text("Save", "保存"),
                                    action: #selector(NSDocument.save(_:)),
                                    keyEquivalent: "")
        ShortcutManager.configure(save, commandID: "file.save")

        let saveAs = fileMenu.addItem(withTitle: AppCopy.text("Save As…", "另存为…"),
                                      action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "")
        ShortcutManager.configure(saveAs, commandID: "file.saveAs")

        fileMenu.addItem(withTitle: AppCopy.text("Revert To Saved", "恢复到已保存版本"),
                         action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")

        fileMenu.addItem(NSMenuItem.separator())

        fileMenu.addItem(withTitle: AppCopy.text("Rename…", "重命名…"),
                         action: #selector(Document.rename(_:)),
                         keyEquivalent: "")

        fileMenu.addItem(withTitle: AppCopy.text("Move To…", "移动到…"),
                         action: #selector(Document.move(_:)),
                         keyEquivalent: "")

        fileMenu.addItem(NSMenuItem.separator())

        let exportPDF = fileMenu.addItem(withTitle: AppCopy.text("Export as PDF…", "导出为 PDF…"),
                                         action: #selector(Document.exportToPDF(_:)),
                                         keyEquivalent: "")
        ShortcutManager.configure(exportPDF, commandID: "file.exportPDF")

        let print = fileMenu.addItem(withTitle: AppCopy.text("Print…", "打印…"),
                                     action: #selector(Document.printDocument(_:)),
                                     keyEquivalent: "")
        ShortcutManager.configure(print, commandID: "file.print")

        fileMenu.addItem(NSMenuItem.separator())
        let close = fileMenu.addItem(withTitle: AppCopy.text("Close", "关闭"),
                                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        ShortcutManager.configure(close, commandID: "file.close")

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (required for Cmd+C/V/X/A/Z)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: AppCopy.text("Edit", "编辑"))

        let undo = editMenu.addItem(withTitle: AppCopy.text("Undo", "撤销"),
                                    action: #selector(EditorTextView.undo(_:)),
                                    keyEquivalent: "")
        ShortcutManager.configure(undo, commandID: "edit.undo")

        let redoItem = editMenu.addItem(withTitle: AppCopy.text("Redo", "重做"),
                                        action: #selector(EditorTextView.redo(_:)),
                                        keyEquivalent: "")
        ShortcutManager.configure(redoItem, commandID: "edit.redo")

        editMenu.addItem(NSMenuItem.separator())

        let cut = editMenu.addItem(withTitle: AppCopy.text("Cut", "剪切"),
                                   action: #selector(NSText.cut(_:)),
                                   keyEquivalent: "")
        ShortcutManager.configure(cut, commandID: "edit.cut")

        let copy = editMenu.addItem(withTitle: AppCopy.text("Copy", "复制"),
                                    action: #selector(NSText.copy(_:)),
                                    keyEquivalent: "")
        ShortcutManager.configure(copy, commandID: "edit.copy")

        let paste = editMenu.addItem(withTitle: AppCopy.text("Paste", "粘贴"),
                                     action: #selector(NSText.paste(_:)),
                                     keyEquivalent: "")
        ShortcutManager.configure(paste, commandID: "edit.paste")

        let pastePlain = editMenu.addItem(
            withTitle: AppCopy.text("Paste and Match Style", "粘贴并匹配样式"),
            action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "")
        ShortcutManager.configure(pastePlain, commandID: "edit.pasteAndMatchStyle")

        let selectAll = editMenu.addItem(withTitle: AppCopy.text("Select All", "全选"),
                                         action: #selector(NSText.selectAll(_:)),
                                         keyEquivalent: "")
        ShortcutManager.configure(selectAll, commandID: "edit.selectAll")

        editMenu.addItem(.separator())
        editMenu.addItem(findSubmenuItem())
        editMenu.addItem(spellingSubmenuItem())

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Format menu — built from the declarative command registry.
        mainMenu.addItem(FormatMenu.build())

        // View menu — built in its own file (ViewMenu.swift).
        mainMenu.addItem(ViewMenu.build())

        let windowMenuItem = NSMenuItem()
        let windowMenu = buildWindowMenu()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    private func findSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: AppCopy.text("Find", "查找"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: parent.title)
        menu.addItem(findItem(AppCopy.text("Find…", "查找…"),
                              action: .showFindPanel, commandID: "edit.find"))
        menu.addItem(findItem(AppCopy.text("Find Next", "查找下一个"),
                              action: .next, commandID: "edit.findNext"))
        let previous = findItem(AppCopy.text("Find Previous", "查找上一个"),
                                action: .previous, commandID: "edit.findPrevious")
        menu.addItem(previous)
        let jump = menu.addItem(withTitle: AppCopy.text("Jump to Selection", "跳到所选内容"),
                                action: #selector(NSTextView.centerSelectionInVisibleArea(_:)),
                                keyEquivalent: "")
        ShortcutManager.configure(jump, commandID: "edit.jumpToSelection")
        parent.submenu = menu
        return parent
    }

    private func findItem(_ title: String,
                          action: NSFindPanelAction,
                          commandID: String) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(NSTextView.performFindPanelAction(_:)),
                              keyEquivalent: "")
        item.tag = Int(action.rawValue)
        ShortcutManager.configure(item, commandID: commandID)
        return item
    }

    private func spellingSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: AppCopy.text("Spelling and Grammar", "拼写与语法"),
                                action: nil, keyEquivalent: "")
        let menu = NSMenu(title: parent.title)
        let showSpelling = menu.addItem(
            withTitle: AppCopy.text("Show Spelling and Grammar", "显示拼写与语法"),
            action: #selector(NSTextView.showGuessPanel(_:)),
            keyEquivalent: ""
        )
        ShortcutManager.configure(showSpelling, commandID: "edit.showSpelling")
        let checkSpelling = menu.addItem(
            withTitle: AppCopy.text("Check Document Now", "立即检查文档"),
            action: #selector(NSTextView.checkSpelling(_:)),
            keyEquivalent: ""
        )
        ShortcutManager.configure(checkSpelling, commandID: "edit.checkSpelling")
        menu.addItem(.separator())
        menu.addItem(withTitle: AppCopy.text("Check Spelling While Typing", "键入时检查拼写"),
                     action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        menu.addItem(withTitle: AppCopy.text("Check Grammar With Spelling", "同时检查语法"),
                     action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    private func buildWindowMenu() -> NSMenu {
        let menu = NSMenu(title: AppCopy.text("Window", "窗口"))
        let minimize = menu.addItem(withTitle: AppCopy.text("Minimize", "最小化"),
                                    action: #selector(NSWindow.performMiniaturize(_:)),
                                    keyEquivalent: "")
        ShortcutManager.configure(minimize, commandID: "window.minimize")
        let compact = menu.addItem(
            withTitle: AppCopy.text("Shrink to Minimum Window", "缩至最小窗口"),
            action: #selector(Document.shrinkToMinimumWindow(_:)),
            keyEquivalent: ""
        )
        ShortcutManager.configure(compact, commandID: "window.compact")
        menu.addItem(withTitle: AppCopy.text("Zoom", "缩放"),
                     action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let alwaysOnTop = menu.addItem(
            withTitle: AppCopy.text(
                "Keep Window on Top in Current Space",
                "仅在当前 Space 置顶"
            ),
            action: #selector(AppDelegate.toggleDocumentAlwaysOnTop(_:)),
            keyEquivalent: ""
        )
        alwaysOnTop.target = self
        ShortcutManager.configure(alwaysOnTop, commandID: "window.toggleAlwaysOnTop")
        let alwaysOnTopAcrossSpaces = menu.addItem(
            withTitle: AppCopy.text(
                "Keep Window on Top in All Spaces",
                "跨所有 Space 置顶"
            ),
            action: #selector(AppDelegate.toggleDocumentAlwaysOnTopAcrossSpaces(_:)),
            keyEquivalent: ""
        )
        alwaysOnTopAcrossSpaces.target = self
        ShortcutManager.configure(
            alwaysOnTopAcrossSpaces,
            commandID: "window.toggleAlwaysOnTopAcrossSpaces"
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: AppCopy.text("Bring All to Front", "全部置于前台"),
                     action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}

// --- Launch -----------------------------------------------------------------
let app = NSApplication.shared

// Must be created before NSDocumentController.shared is first accessed.
let documentController = DocumentController()

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()

import AppKit
import FloralMDCore

@MainActor
enum CommandDispatcher {
    private static let documentRequiredCommands: Set<String> = [
        "file.save",
        "file.saveAs",
        "file.commitCurrentFile",
        "file.exportPDF",
        "file.print",
        "file.close",
        "view.toggleOutlineSidebar",
        "view.toggleNavigationSidebar",
        "view.toggleMode",
        "view.toggleFullScreen",
        "view.actualSize",
        "view.zoomIn",
        "view.zoomOut",
        "window.minimize",
        "window.compact",
        "window.toggleAlwaysOnTop",
        "window.toggleAlwaysOnTopAcrossSpaces",
    ]

    private struct Invocation {
        let action: Selector
        let target: AnyObject?
        let tag: Int
        let representedObject: Any?

        init(_ action: Selector,
             target: AnyObject? = nil,
             tag: Int = 0,
             representedObject: Any? = nil) {
            self.action = action
            self.target = target
            self.tag = tag
            self.representedObject = representedObject
        }
    }

    static func supports(_ commandID: String) -> Bool {
        invocation(for: commandID) != nil
    }

    static func canExecute(_ commandID: String) -> Bool {
        if commandID == "file.openRecent" {
            guard let controller = NSDocumentController.shared as? DocumentController else {
                return false
            }
            return !controller.availableRecentDocumentURLs().isEmpty
        }
        if documentRequiredCommands.contains(commandID),
           NSDocumentController.shared.currentDocument == nil {
            return false
        }
        guard let invocation = invocation(for: commandID) else { return false }
        let sender = sender(for: commandID, invocation: invocation)
        return invocation.target != nil
            || NSApp.target(
                forAction: invocation.action,
                to: nil,
                from: sender
            ) != nil
    }

    @discardableResult
    static func execute(_ commandID: String) -> Bool {
        guard canExecute(commandID) else { return false }
        guard let invocation = invocation(for: commandID) else { return false }
        let sender = sender(for: commandID, invocation: invocation)
        return NSApp.sendAction(
            invocation.action,
            to: invocation.target,
            from: sender
        )
    }

    private static func sender(for commandID: String,
                               invocation: Invocation) -> NSMenuItem {
        let definition = ShortcutCatalog.byID[commandID]
        let title = definition.map {
            AppCopy.text($0.englishTitle, $0.chineseTitle)
        } ?? commandID
        let item = NSMenuItem(title: title, action: invocation.action, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(commandID)
        item.tag = invocation.tag
        item.representedObject = invocation.representedObject
        return item
    }

    private static func invocation(for commandID: String) -> Invocation? {
        let appDelegate = NSApp.delegate as? AppDelegate

        switch commandID {
        case "app.settings":
            return Invocation(#selector(AppDelegate.showSettings(_:)), target: appDelegate)
        case "app.checkUpdates":
            return Invocation(#selector(AppDelegate.checkForUpdates(_:)), target: appDelegate)
        case "file.new":
            return Invocation(
                #selector(DocumentController.newDocumentTab(_:)),
                target: NSDocumentController.shared
            )
        case "file.newWindow":
            return Invocation(
                #selector(DocumentController.newDocumentWindow(_:)),
                target: NSDocumentController.shared
            )
        case "file.quickCapture":
            return Invocation(#selector(AppDelegate.performQuickCapture(_:)), target: appDelegate)
        case "file.open":
            return Invocation(#selector(AppDelegate.openDocumentManually(_:)), target: appDelegate)
        case "file.openRecent":
            return Invocation(#selector(AppDelegate.showRecentDocuments(_:)), target: appDelegate)
        case "file.openInNewWindow":
            return Invocation(
                #selector(AppDelegate.openDocumentInNewWindowManually(_:)),
                target: appDelegate
            )
        case "file.save":
            return Invocation(#selector(NSDocument.save(_:)))
        case "file.saveAs":
            return Invocation(#selector(NSDocument.saveAs(_:)))
        case "file.commitCurrentFile":
            return Invocation(#selector(Document.commitCurrentFile(_:)))
        case "file.exportPDF":
            return Invocation(#selector(Document.exportToPDF(_:)))
        case "file.print":
            return Invocation(#selector(Document.printDocument(_:)))
        case "file.close":
            return Invocation(#selector(NSWindow.performClose(_:)))
        case "view.toggleOutlineSidebar":
            return Invocation(#selector(Document.toggleOutlineSidebar(_:)))
        case "view.toggleNavigationSidebar":
            return Invocation(#selector(Document.toggleNavigationSidebar(_:)))
        case "view.toggleMinimap":
            return Invocation(#selector(AppDelegate.toggleMinimap(_:)), target: appDelegate)
        case "view.toggleTypewriter":
            return Invocation(#selector(AppDelegate.toggleTypewriterMode(_:)), target: appDelegate)
        case "view.toggleMode":
            return Invocation(#selector(Document.toggleViewMode(_:)))
        case "view.toggleSource":
            return Invocation(#selector(AppDelegate.toggleSourceMode(_:)), target: appDelegate)
        case "view.toggleFullScreen":
            return Invocation(
                #selector(AppDelegate.toggleDocumentFullScreen(_:)),
                target: appDelegate
            )
        case "view.actualSize":
            return Invocation(#selector(Document.actualSize(_:)))
        case "view.zoomIn":
            return Invocation(#selector(Document.zoomIn(_:)))
        case "view.zoomOut":
            return Invocation(#selector(Document.zoomOut(_:)))
        case "window.minimize":
            return Invocation(#selector(NSWindow.performMiniaturize(_:)))
        case "window.compact":
            return Invocation(#selector(Document.shrinkToMinimumWindow(_:)))
        case "window.toggleAlwaysOnTop":
            return Invocation(
                #selector(AppDelegate.toggleDocumentAlwaysOnTop(_:)),
                target: appDelegate
            )
        case "window.toggleAlwaysOnTopAcrossSpaces":
            return Invocation(
                #selector(AppDelegate.toggleDocumentAlwaysOnTopAcrossSpaces(_:)),
                target: appDelegate
            )
        case "format.bulletedList":
            return Invocation(#selector(EditorTextView.formatBulletedList(_:)))
        case "format.numberedList":
            return Invocation(#selector(EditorTextView.formatNumberedList(_:)))
        case "format.checklist":
            return Invocation(#selector(EditorTextView.formatChecklist(_:)))
        case "format.link":
            return Invocation(#selector(EditorTextView.formatLink(_:)))
        case "format.wikilink":
            return Invocation(#selector(EditorTextView.formatWikilink(_:)))
        case "format.image":
            return Invocation(#selector(Document.insertImageReference(_:)))
        case "format.thematicBreak":
            return Invocation(#selector(EditorTextView.formatThematicBreak(_:)))
        case "format.footnote":
            return Invocation(#selector(EditorTextView.formatFootnote(_:)))
        case "format.table":
            return Invocation(#selector(EditorTextView.formatTable(_:)))
        case "format.codeBlock":
            return Invocation(#selector(EditorTextView.formatCodeBlock(_:)))
        case "format.mathBlock":
            return Invocation(#selector(EditorTextView.formatMathBlock(_:)))
        case "format.blockQuote":
            return Invocation(#selector(EditorTextView.formatBlockQuote(_:)))
        case "format.bold":
            return Invocation(#selector(EditorTextView.formatBold(_:)))
        case "format.italic":
            return Invocation(#selector(EditorTextView.formatItalic(_:)))
        case "format.underline":
            return Invocation(#selector(EditorTextView.formatUnderline(_:)))
        case "format.strikethrough":
            return Invocation(#selector(EditorTextView.formatStrikethrough(_:)))
        case "format.highlight":
            return Invocation(#selector(EditorTextView.formatHighlight(_:)))
        case "format.code":
            return Invocation(#selector(EditorTextView.formatCode(_:)))
        case "format.math":
            return Invocation(#selector(EditorTextView.formatInlineMath(_:)))
        case "format.keyboard":
            return Invocation(#selector(EditorTextView.formatKeyboard(_:)))
        case "format.comment":
            return Invocation(#selector(EditorTextView.formatComment(_:)))
        default:
            if commandID.hasPrefix("format.heading"),
               let level = Int(commandID.dropFirst("format.heading".count)) {
                return Invocation(#selector(EditorTextView.formatHeading(_:)), tag: level)
            }
            if commandID.hasPrefix("format.callout.") {
                return Invocation(
                    #selector(EditorTextView.formatCallout(_:)),
                    representedObject: String(commandID.dropFirst("format.callout.".count))
                )
            }
            return nil
        }
    }
}

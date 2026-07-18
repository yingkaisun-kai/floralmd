// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit
import FloralMDCore

// MARK: - Format menu (declarative command registry)
//
// Stable IDs, defaults, customization policy, and persistence live in
// `ShortcutCatalog`. This file only maps those IDs to responder-chain actions.

/// One actionable menu command.
struct MenuCommand {
    let id: String
    let title: String
    let action: Selector
    var tag: Int = 0
    var representedObject: Any? = nil

    @MainActor
    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.tag = tag
        item.representedObject = representedObject
        ShortcutManager.configure(item, commandID: id)
        // nil target → responder chain (focused EditorTextView / Document).
        return item
    }
}

@MainActor
enum FormatMenu {

    /// The top-level "Format" menu item (with its submenu).
    static func build() -> NSMenuItem {
        let formatItem = NSMenuItem()
        let menu = NSMenu(title: AppCopy.text("Format", "格式"))

        menu.addItem(headingSubmenuItem())
        menu.addItem(thematicBreakCommand.makeItem())
        menu.addItem(.separator())

        for cmd in listCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(.separator())

        for cmd in linkCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(.separator())

        for cmd in blockCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(calloutSubmenuItem())
        menu.addItem(footnoteCommand.makeItem())
        menu.addItem(.separator())

        menu.addItem(fontSubmenuItem())

        formatItem.submenu = menu
        return formatItem
    }

    /// The "Toggle View Mode" item (⌘E) for the View menu — bracketed by
    /// dividers by the caller.
    static func viewModeToggleItem() -> NSMenuItem {
        MenuCommand(id: "view.toggleMode", title: AppCopy.text("Toggle View Mode", "切换视图模式"),
                    action: #selector(Document.toggleViewMode(_:))).makeItem()
    }

    // MARK: - Groups

    private static var listCommands: [MenuCommand] { [
        MenuCommand(id: "format.bulletedList", title: AppCopy.text("Bulleted List", "项目符号列表"),
                    action: #selector(EditorTextView.formatBulletedList(_:))),
        MenuCommand(id: "format.numberedList", title: AppCopy.text("Numbered List", "编号列表"),
                    action: #selector(EditorTextView.formatNumberedList(_:))),
        MenuCommand(id: "format.checklist", title: AppCopy.text("Checklist", "任务列表"),
                    action: #selector(EditorTextView.formatChecklist(_:))),
    ] }

    private static var linkCommands: [MenuCommand] { [
        MenuCommand(id: "format.link", title: AppCopy.text("Link", "链接"),
                    action: #selector(EditorTextView.formatLink(_:))),
        MenuCommand(id: "format.wikilink", title: AppCopy.text("Wikilink", "Wiki 链接"),
                    action: #selector(EditorTextView.formatWikilink(_:))),
        MenuCommand(id: "format.image", title: AppCopy.text("Image", "图片"),
                    action: #selector(EditorTextView.formatImage(_:))),
    ] }

    private static var thematicBreakCommand: MenuCommand { MenuCommand(id: "format.thematicBreak", title: AppCopy.text("Thematic Break", "分隔线"),
                    action: #selector(EditorTextView.formatThematicBreak(_:)))
    }

    private static var footnoteCommand: MenuCommand { MenuCommand(id: "format.footnote", title: AppCopy.text("Footnote", "脚注"),
                    action: #selector(EditorTextView.formatFootnote(_:)))
    }

    private static var blockCommands: [MenuCommand] { [
        MenuCommand(id: "format.table", title: AppCopy.text("Table", "表格"),
                    action: #selector(EditorTextView.formatTable(_:))),
        MenuCommand(id: "format.codeBlock", title: AppCopy.text("Code Block", "代码块"),
                    action: #selector(EditorTextView.formatCodeBlock(_:))),
        MenuCommand(id: "format.mathBlock", title: AppCopy.text("Math Block", "公式块"),
                    action: #selector(EditorTextView.formatMathBlock(_:))),
        MenuCommand(id: "format.blockQuote", title: AppCopy.text("Block Quote", "引用块"),
                    action: #selector(EditorTextView.formatBlockQuote(_:))),
    ] }

    private static var fontCommands: [MenuCommand] { [
        MenuCommand(id: "format.bold", title: AppCopy.text("Bold", "粗体"),
                    action: #selector(EditorTextView.formatBold(_:))),
        MenuCommand(id: "format.italic", title: AppCopy.text("Italic", "斜体"),
                    action: #selector(EditorTextView.formatItalic(_:))),
        MenuCommand(id: "format.underline", title: AppCopy.text("Underline", "下划线"),
                    action: #selector(EditorTextView.formatUnderline(_:))),
        MenuCommand(id: "format.strikethrough", title: AppCopy.text("Strikethrough", "删除线"),
                    action: #selector(EditorTextView.formatStrikethrough(_:))),
        MenuCommand(id: "format.highlight", title: AppCopy.text("Highlight", "高亮"),
                    action: #selector(EditorTextView.formatHighlight(_:))),
        MenuCommand(id: "format.code", title: AppCopy.text("Code", "行内代码"),
                    action: #selector(EditorTextView.formatCode(_:))),
        MenuCommand(id: "format.math", title: AppCopy.text("Math", "行内公式"),
                    action: #selector(EditorTextView.formatInlineMath(_:))),
        MenuCommand(id: "format.keyboard", title: AppCopy.text("Keyboard", "键盘按键"),
                    action: #selector(EditorTextView.formatKeyboard(_:))),
        MenuCommand(id: "format.comment", title: AppCopy.text("Comments", "注释"),
                    action: #selector(EditorTextView.formatComment(_:))),
    ] }

    /// GitHub alert types (uppercase in source: `> [!NOTE]`).
    private static let githubCalloutTypes = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]

    /// Obsidian-only callout types (lowercase). note/tip/warning are omitted
    /// since they duplicate NOTE/TIP/WARNING already in the GitHub group.
    private static let obsidianCalloutTypes = [
        "abstract", "info", "todo", "success", "question",
        "failure", "danger", "bug", "example", "quote",
    ]

    // MARK: - Submenus

    private static func headingSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: AppCopy.text("Heading", "标题"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: AppCopy.text("Heading", "标题"))
        for level in 1...6 {
            menu.addItem(MenuCommand(id: "format.heading\(level)", title: AppCopy.text("Heading \(level)", "标题 \(level)"),
                                     action: #selector(EditorTextView.formatHeading(_:)),
                                     tag: level).makeItem())
        }
        item.submenu = menu
        return item
    }

    private static func calloutSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: AppCopy.text("Alert / Callout", "提示框 / Callout"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: AppCopy.text("Alert / Callout", "提示框 / Callout"))
        for type in githubCalloutTypes {
            menu.addItem(MenuCommand(id: "format.callout.\(type)", title: type.capitalized,
                                     action: #selector(EditorTextView.formatCallout(_:)),
                                     representedObject: type).makeItem())
        }
        menu.addItem(.separator())
        for type in obsidianCalloutTypes {
            menu.addItem(MenuCommand(id: "format.callout.\(type)", title: type.capitalized,
                                     action: #selector(EditorTextView.formatCallout(_:)),
                                     representedObject: type).makeItem())
        }
        item.submenu = menu
        return item
    }

    private static func fontSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: AppCopy.text("Font", "字体"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: AppCopy.text("Font", "字体"))
        for cmd in fontCommands { menu.addItem(cmd.makeItem()) }
        item.submenu = menu
        return item
    }
}

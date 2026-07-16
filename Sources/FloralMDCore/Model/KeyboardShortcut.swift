import AppKit

public struct CommandShortcut: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable {
        case application
        case global
    }

    public let scope: Scope
    public let keyEquivalent: String
    public let modifiersRawValue: UInt
    public let keyCode: UInt16?
    public let keyLabel: String

    public init(scope: Scope,
                keyEquivalent: String,
                modifiers: NSEvent.ModifierFlags,
                keyCode: UInt16? = nil,
                keyLabel: String? = nil) {
        self.scope = scope
        self.keyEquivalent = keyEquivalent.lowercased()
        self.modifiersRawValue = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
        self.keyCode = keyCode
        self.keyLabel = keyLabel ?? keyEquivalent.uppercased()
    }

    public var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    public var displayName: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + keyLabel
    }

    public var collisionKey: String {
        "\(modifiersRawValue):\(keyEquivalent)"
    }

    public static func application(_ key: String,
                                   _ modifiers: NSEvent.ModifierFlags = [.command]) -> Self {
        Self(scope: .application, keyEquivalent: key, modifiers: modifiers)
    }

    public static func global(_ keyCode: UInt16,
                              keyEquivalent: String,
                              keyLabel: String,
                              modifiers: NSEvent.ModifierFlags) -> Self {
        Self(scope: .global,
             keyEquivalent: keyEquivalent,
             modifiers: modifiers,
             keyCode: keyCode,
             keyLabel: keyLabel)
    }
}

public struct ShortcutCommandDefinition: Equatable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case application
        case file
        case edit
        case view
        case format
        case window
        case global
    }

    public let id: String
    public let category: Category
    public let englishTitle: String
    public let chineseTitle: String
    public let defaultShortcut: CommandShortcut?
    public let isCustomizable: Bool
    public let productionOnly: Bool
    public let appearsInCommandPalette: Bool

    public init(id: String,
                category: Category,
                englishTitle: String,
                chineseTitle: String,
                defaultShortcut: CommandShortcut?,
                isCustomizable: Bool,
                productionOnly: Bool = false,
                appearsInCommandPalette: Bool = true) {
        self.id = id
        self.category = category
        self.englishTitle = englishTitle
        self.chineseTitle = chineseTitle
        self.defaultShortcut = defaultShortcut
        self.isCustomizable = isCustomizable
        self.productionOnly = productionOnly
        self.appearsInCommandPalette = appearsInCommandPalette
    }
}

public enum ShortcutCatalog {
    private static let command = NSEvent.ModifierFlags.command
    private static let commandShift: NSEvent.ModifierFlags = [.command, .shift]
    private static let commandOption: NSEvent.ModifierFlags = [.command, .option]
    private static let commandControl: NSEvent.ModifierFlags = [.command, .control]
    private static let commandControlShift: NSEvent.ModifierFlags = [.command, .control, .shift]
    private static let commandOptionShift: NSEvent.ModifierFlags = [.command, .option, .shift]

    public static let definitions: [ShortcutCommandDefinition] = [
        locked("app.settings", .application, "Settings…", "设置…", ",",
               appearsInCommandPalette: true),
    ] + productionDefinitions + [
        custom("app.commandPalette", .application, "Command Palette…", "命令面板…",
               .application("p", commandShift), appearsInCommandPalette: false),
        locked("app.hide", .application, "Hide FloralMD", "隐藏 FloralMD", "h",
               appearsInCommandPalette: false),
        locked("app.hideOthers", .application, "Hide Others", "隐藏其他应用", "h", commandOption,
               appearsInCommandPalette: false),
        locked("app.quit", .application, "Quit FloralMD", "退出 FloralMD", "q",
               appearsInCommandPalette: false),

        locked("file.new", .file, "New", "新建", "n", appearsInCommandPalette: true),
        locked("file.open", .file, "Open…", "打开…", "o", appearsInCommandPalette: true),
        locked("file.save", .file, "Save", "保存", "s", appearsInCommandPalette: true),
        locked("file.saveAs", .file, "Save As…", "另存为…", "s", commandShift,
               appearsInCommandPalette: true),
        custom("file.exportPDF", .file, "Export as PDF…", "导出为 PDF…",
               .application("p", commandOption)),
        locked("file.print", .file, "Print…", "打印…", "p", appearsInCommandPalette: true),
        locked("file.close", .file, "Close", "关闭", "w", appearsInCommandPalette: true),

        locked("edit.undo", .edit, "Undo", "撤销", "z", appearsInCommandPalette: false),
        locked("edit.redo", .edit, "Redo", "重做", "z", commandShift,
               appearsInCommandPalette: false),
        locked("edit.cut", .edit, "Cut", "剪切", "x", appearsInCommandPalette: false),
        locked("edit.copy", .edit, "Copy", "复制", "c", appearsInCommandPalette: false),
        locked("edit.paste", .edit, "Paste", "粘贴", "v", appearsInCommandPalette: false),
        locked("edit.pasteAndMatchStyle", .edit, "Paste and Match Style", "粘贴并匹配样式",
               "v", commandOptionShift, appearsInCommandPalette: false),
        locked("edit.selectAll", .edit, "Select All", "全选", "a",
               appearsInCommandPalette: false),
        locked("edit.find", .edit, "Find…", "查找…", "f"),
        locked("edit.findNext", .edit, "Find Next", "查找下一个", "g"),
        locked("edit.findPrevious", .edit, "Find Previous", "查找上一个", "g", commandShift),
        locked("edit.jumpToSelection", .edit, "Jump to Selection", "跳到所选内容", "j"),
        locked("edit.showSpelling", .edit, "Show Spelling and Grammar", "显示拼写与语法", ":"),
        locked("edit.checkSpelling", .edit, "Check Document Now", "立即检查文档", ";"),

        custom("view.toggleOutlineSidebar", .view, "Toggle Outline Sidebar", "切换大纲侧栏",
               .application("b", commandControl)),
        custom("view.toggleNavigationSidebar", .view, "Toggle File Sidebar", "切换文件侧栏",
               .application("b", commandControlShift)),
        custom("view.toggleMinimap", .view, "Show Minimap", "显示缩略图", nil),
        custom("view.toggleTypewriter", .view, "Typewriter Scroll", "打字机滚动",
               .application("y", commandOption)),
        custom("view.toggleMode", .view, "Toggle View Mode", "切换视图模式",
               .application("e", command)),
        custom("view.toggleSource", .view, "Show Source in Editor", "在编辑器中显示源码",
               .application("e", commandOption)),
        locked("view.toggleFullScreen", .view, "Enter Full Screen", "进入全屏",
               "f", commandControl, appearsInCommandPalette: true),
        locked("view.actualSize", .view, "Actual Size", "实际大小", "0",
               appearsInCommandPalette: true),
        locked("view.zoomIn", .view, "Zoom In", "放大", "=",
               appearsInCommandPalette: true),
        locked("view.zoomOut", .view, "Zoom Out", "缩小", "-",
               appearsInCommandPalette: true),

        locked("window.minimize", .window, "Minimize", "最小化", "m",
               appearsInCommandPalette: true),
        custom("window.compact", .window, "Shrink to Minimum Window", "缩至最小窗口", nil),
        custom("window.toggleAlwaysOnTop", .window,
               "Keep Window on Top in Current Space", "仅在当前 Space 置顶", nil),
        custom("window.toggleAlwaysOnTopAcrossSpaces", .window,
               "Keep Window on Top in All Spaces", "跨所有 Space 置顶", nil),

        custom("format.bulletedList", .format, "Bulleted List", "项目符号列表",
               .application("8", commandShift)),
        custom("format.numberedList", .format, "Numbered List", "编号列表",
               .application("7", commandShift)),
        custom("format.checklist", .format, "Checklist", "任务列表",
               .application("l", commandOption)),
        custom("format.link", .format, "Link", "链接", .application("k")),
        custom("format.wikilink", .format, "Wikilink", "Wiki 链接",
               .application("k", commandOption)),
        custom("format.image", .format, "Image", "图片", .application("k", commandShift)),
        custom("format.thematicBreak", .format, "Thematic Break", "分隔线",
               .application("-", commandShift)),
        custom("format.footnote", .format, "Footnote", "脚注",
               .application("f", commandOption)),
        custom("format.table", .format, "Table", "表格",
               .application("t", commandOptionShift)),
        custom("format.codeBlock", .format, "Code Block", "代码块",
               .application("c", commandOption)),
        custom("format.mathBlock", .format, "Math Block", "公式块",
               .application("m", commandOptionShift)),
        custom("format.blockQuote", .format, "Block Quote", "引用块",
               .application(".", commandShift)),
        custom("format.bold", .format, "Bold", "粗体", .application("b")),
        custom("format.italic", .format, "Italic", "斜体", .application("i")),
        custom("format.underline", .format, "Underline", "下划线", .application("u")),
        custom("format.strikethrough", .format, "Strikethrough", "删除线",
               .application("x", commandShift)),
        custom("format.highlight", .format, "Highlight", "高亮",
               .application("h", commandShift)),
        custom("format.code", .format, "Code", "行内代码",
               .application("c", commandShift)),
        custom("format.math", .format, "Math", "行内公式",
               .application("m", commandShift)),
        custom("format.keyboard", .format, "Keyboard", "键盘按键",
               .application("k", commandOptionShift)),
        custom("format.comment", .format, "Comments", "注释",
               .application("/", commandOption)),

        custom("file.quickCapture", .global, "Quick Capture", "快速记录",
               .global(45,
                       keyEquivalent: "n",
                       keyLabel: "N",
                       modifiers: [.control, .option, .command])),
    ] + (1...6).map {
        custom("format.heading\($0)", .format, "Heading \($0)", "标题 \($0)",
               CommandShortcut.application("\($0)", commandOption))
    } + [
        ("NOTE", "Note", "Note"),
        ("TIP", "Tip", "Tip"),
        ("IMPORTANT", "Important", "Important"),
        ("WARNING", "Warning", "Warning"),
        ("CAUTION", "Caution", "Caution"),
        ("abstract", "Abstract", "Abstract"),
        ("info", "Info", "Info"),
        ("todo", "Todo", "Todo"),
        ("success", "Success", "Success"),
        ("question", "Question", "Question"),
        ("failure", "Failure", "Failure"),
        ("danger", "Danger", "Danger"),
        ("bug", "Bug", "Bug"),
        ("example", "Example", "Example"),
        ("quote", "Quote", "Quote"),
    ].map {
        custom("format.callout.\($0.0)", .format, "Callout: \($0.1)", "提示框：\($0.2)", nil)
    }

    #if FLORALMD_PRODUCTION
    private static let productionDefinitions = [
        custom("app.checkUpdates", .application, "Check for Updates…", "检查更新…", nil,
               productionOnly: true),
    ]
    #else
    private static let productionDefinitions: [ShortcutCommandDefinition] = []
    #endif

    public static let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })

    public static func conflicts(in shortcuts: [String: CommandShortcut]) -> [String: String] {
        var ownerByCollision: [String: String] = [:]
        var conflicts: [String: String] = [:]
        for definition in definitions {
            guard let shortcut = shortcuts[definition.id] else { continue }
            let key = shortcut.collisionKey
            if let owner = ownerByCollision[key] {
                conflicts[definition.id] = owner
                conflicts[owner] = definition.id
            } else {
                ownerByCollision[key] = definition.id
            }
        }
        return conflicts
    }

    private static func locked(_ id: String,
                               _ category: ShortcutCommandDefinition.Category,
                               _ english: String,
                               _ chinese: String,
                               _ key: String,
                               _ modifiers: NSEvent.ModifierFlags = [.command],
                               appearsInCommandPalette: Bool = false)
        -> ShortcutCommandDefinition {
        ShortcutCommandDefinition(id: id,
                                  category: category,
                                  englishTitle: english,
                                  chineseTitle: chinese,
                                  defaultShortcut: .application(key, modifiers),
                                  isCustomizable: false,
                                  appearsInCommandPalette: appearsInCommandPalette)
    }

    private static func custom(_ id: String,
                               _ category: ShortcutCommandDefinition.Category,
                               _ english: String,
                               _ chinese: String,
                               _ shortcut: CommandShortcut?,
                               productionOnly: Bool = false,
                               appearsInCommandPalette: Bool = true)
        -> ShortcutCommandDefinition {
        ShortcutCommandDefinition(id: id,
                                  category: category,
                                  englishTitle: english,
                                  chineseTitle: chinese,
                                  defaultShortcut: shortcut,
                                  isCustomizable: true,
                                  productionOnly: productionOnly,
                                  appearsInCommandPalette: appearsInCommandPalette)
    }
}

public enum ShortcutOverride: Codable, Equatable, Sendable {
    case shortcut(CommandShortcut)
    case disabled

    private enum CodingKeys: String, CodingKey {
        case shortcut
        case disabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .disabled) == true {
            self = .disabled
        } else {
            self = .shortcut(try container.decode(CommandShortcut.self, forKey: .shortcut))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .shortcut(let shortcut):
            try container.encode(shortcut, forKey: .shortcut)
        case .disabled:
            try container.encode(true, forKey: .disabled)
        }
    }
}

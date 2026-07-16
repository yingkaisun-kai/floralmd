import AppKit
import FloralMDCore
import SwiftUI

struct ShortcutsSettingsView: View {
    @AppStorage(AppSettings.Key.interfaceLanguage) private var language = AppLanguage.system
    @AppStorage(AppSettings.Key.showFixedShortcuts) private var showFixedShortcuts = false
    @State private var searchText = ""
    @State private var conflictMessage: String?
    @State private var refreshToken = UUID()

    private func tr(_ en: String, _ zh: String) -> String {
        AppCopy.text(en, zh, language: language)
    }

    private var visibleDefinitions: [ShortcutCommandDefinition] {
        let query = normalized(searchText)
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return ShortcutCatalog.definitions.filter { definition in
            guard showFixedShortcuts || definition.isCustomizable else { return false }
            guard !tokens.isEmpty else { return true }
            let shortcut = AppSettings.effectiveShortcut(for: definition.id)
                .map(ShortcutManager.displayName(for:)) ?? ""
            let scope = definition.defaultShortcut?.scope == .global
                ? tr("system-wide global", "系统级全局")
                : tr("application", "应用内")
            let policy = definition.isCustomizable
                ? tr("customizable", "可修改")
                : tr("macOS standard fixed", "macOS 标准 固定")
            let searchable = normalized([
                definition.englishTitle,
                definition.chineseTitle,
                definition.id,
                categoryTitle(definition.category),
                shortcut,
                scope,
                policy,
            ].joined(separator: " "))
            return tokens.allSatisfy(searchable.contains)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr(
                "FloralMD commands can be changed or cleared. Fixed macOS standard shortcuts can be shown for reference.",
                "FloralMD 命令可以修改或清除；固定的 macOS 标准快捷键可按需显示以供参考。"
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                TextField(tr("Search shortcuts", "搜索快捷键"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(tr("Search shortcuts", "搜索快捷键"))
                Toggle(
                    tr("Show macOS standard shortcuts", "显示 macOS 标准快捷键"),
                    isOn: $showFixedShortcuts
                )
                .toggleStyle(.checkbox)
                .fixedSize()
            }

            if let conflictMessage {
                Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(conflictMessage)
            }

            ScrollView {
                if visibleDefinitions.isEmpty {
                    ContentUnavailableView(
                        tr("No Shortcuts Found", "未找到快捷键"),
                        systemImage: "keyboard",
                        description: Text(tr(
                            "Try another search or show macOS standard shortcuts.",
                            "请尝试其他搜索词，或显示 macOS 标准快捷键。"
                        ))
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(ShortcutCommandDefinition.Category.allCases, id: \.self) { category in
                            let definitions = visibleDefinitions.filter { $0.category == category }
                            if !definitions.isEmpty {
                                shortcutSection(category, definitions: definitions)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Spacer()
                Button(tr("Restore All Defaults", "全部恢复默认")) {
                    conflictMessage = nil
                    ShortcutManager.restoreAllDefaults()
                    refreshToken = UUID()
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: 580, alignment: .topLeading)
        .id(refreshToken)
        .onReceive(NotificationCenter.default.publisher(for: .shortcutSettingsDidChange)) { _ in
            refreshToken = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyboardInputSourceDidChange)) { _ in
            refreshToken = UUID()
        }
    }

    @ViewBuilder
    private func shortcutSection(_ category: ShortcutCommandDefinition.Category,
                                 definitions: [ShortcutCommandDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(categoryTitle(category))
                .font(.headline)
            ForEach(definitions, id: \.id) { definition in
                shortcutRow(definition)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ definition: ShortcutCommandDefinition) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(commandTitle(definition))
                if definition.productionOnly {
                    Text(tr("Production only", "仅正式版"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if definition.defaultShortcut?.scope == .global {
                    Text(tr("System-wide", "系统级全局"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if definition.isCustomizable {
                ShortcutRecorderView(
                    commandTitle: commandTitle(definition),
                    scope: definition.defaultShortcut?.scope ?? .application,
                    shortcut: AppSettings.effectiveShortcut(for: definition.id)
                ) { proposed in
                    apply(proposed, to: definition)
                }
                .frame(width: 132, height: 24)

                Button {
                    conflictMessage = nil
                    ShortcutManager.restoreDefault(for: definition.id)
                    refreshToken = UUID()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help(tr("Restore Default", "恢复默认"))
                .disabled(AppSettings.shortcutOverrides[definition.id] == nil)
                .accessibilityLabel(
                    tr("Restore \(commandTitle(definition)) shortcut", "恢复\(commandTitle(definition))快捷键")
                )
            } else {
                Text(AppSettings.effectiveShortcut(for: definition.id)
                    .map(ShortcutManager.displayName(for:))
                     ?? tr("None", "无"))
                    .frame(width: 132, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(tr("macOS standard", "macOS 标准"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
        }
        .frame(minHeight: 30)
    }

    private func apply(_ proposed: CommandShortcut?,
                       to definition: ShortcutCommandDefinition) {
        conflictMessage = nil
        if let proposed,
           let ownerID = ShortcutManager.conflictOwner(
               for: proposed,
               excluding: definition.id
           ),
           let owner = ShortcutCatalog.byID[ownerID] {
            conflictMessage = tr(
                "\(ShortcutManager.displayName(for: proposed)) is already assigned to \(owner.englishTitle).",
                "\(ShortcutManager.displayName(for: proposed)) 已分配给\(owner.chineseTitle)。"
            )
            NSSound.beep()
            refreshToken = UUID()
            return
        }
        if definition.defaultShortcut?.scope == .global,
           let proposed,
           proposed.modifiers.contains(NSEvent.ModifierFlags([.control, .option])),
           NSWorkspace.shared.isVoiceOverEnabled {
            conflictMessage = tr(
                "Control–Option combinations conflict with VoiceOver while it is running.",
                "VoiceOver 运行时，Control–Option 组合会与其操作键冲突。"
            )
            NSSound.beep()
            refreshToken = UUID()
            return
        }
        ShortcutManager.apply(proposed, to: definition.id)
        refreshToken = UUID()
    }

    private func commandTitle(_ definition: ShortcutCommandDefinition) -> String {
        AppCopy.text(definition.englishTitle, definition.chineseTitle, language: language)
    }

    private func categoryTitle(_ category: ShortcutCommandDefinition.Category) -> String {
        switch category {
        case .application: return tr("Application", "应用")
        case .file: return tr("File", "文件")
        case .edit: return tr("Edit", "编辑")
        case .view: return tr("View", "视图")
        case .format: return tr("Format", "格式")
        case .window: return tr("Window", "窗口")
        case .global: return tr("Global", "全局")
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

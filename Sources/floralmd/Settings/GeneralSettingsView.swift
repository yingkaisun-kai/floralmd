// The General settings pane (startup, document saving, conflict resolution).

import SwiftUI
import AppKit
import FloralMDCore

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Key.interfaceLanguage) private var language = AppLanguage.system
    #if FLORALMD_PRODUCTION
    @AppStorage(AppSettings.Key.automaticallyChecksForUpdates)
    private var autoCheckUpdates = true
    #endif
    @AppStorage(AppSettings.Key.reopenWindows) private var reopenWindows = false
    @AppStorage(AppSettings.Key.startupAction) private var startupAction = AppSettings.StartupAction.createNewDocument
    @AppStorage(AppSettings.Key.autoSaveWithVersions) private var autoSave = true
    @AppStorage(AppSettings.Key.autoSaveInterval) private var autoSaveInterval = 2.0
    @AppStorage(AppSettings.Key.autoSaveUntitledDocuments) private var autoSaveUntitled = false
    @AppStorage(AppSettings.Key.quickCaptureEnabled) private var quickCaptureEnabled = false
    @AppStorage(AppSettings.Key.conflictResolution) private var conflict = AppSettings.ConflictResolution.ask
    @State private var untitledDirectory: URL?
    @State private var isChoosingUntitledDirectory = false

    private func tr(_ en: String, _ zh: String) -> String { AppCopy.text(en, zh, language: language) }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text(tr("Language:", "语言："))
                    .gridColumnAlignment(.trailing)
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName(in: language)).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: language) {
                    NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
                }
            }

            #if FLORALMD_PRODUCTION
            GridRow { Divider().gridCellColumns(2) }
            GridRow {
                Text(tr("Software updates:", "软件更新："))
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(tr("Automatically check for updates", "自动检查更新"), isOn: $autoCheckUpdates)
                }
            }
            
            GridRow {
                Divider().gridCellColumns(2)
            }
            #endif
            
            GridRow {
                Text(tr("On startup:", "启动时："))
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(tr("Reopen windows from last session", "重新打开上次会话的窗口"), isOn: $reopenWindows)
                    Text(tr("When nothing else is open:", "没有其他窗口时："))
                    Picker("", selection: $startupAction) {
                        ForEach(AppSettings.StartupAction.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, 20)
                }
            }

            GridRow {
                Text(tr("Document save:", "文档保存："))
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $autoSave) {
                        Text(tr("Automatically save changes (recommended)", "自动保存修改（推荐）"))
                            .tag(true)
                        Text(tr("Save manually only (⌘S)", "仅手动保存（⌘S）"))
                            .tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: autoSave) {
                        AppSettings.applyDocumentSaving()
                    }

                    HStack(spacing: 8) {
                        Text(tr("Auto-save interval:", "自动保存间隔："))
                        Picker("", selection: $autoSaveInterval) {
                            ForEach(DocumentAutoSaveInterval.allCases) { interval in
                                Text(intervalLabel(interval)).tag(interval.rawValue)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.leading, 20)
                    .disabled(!autoSave && !autoSaveUntitled)
                    .onChange(of: autoSaveInterval) {
                        AppSettings.applyDocumentSaving()
                    }

                    Text(tr("Automatic saving uses macOS Versions so earlier revisions remain recoverable. Manual mode asks before closing a changed document.",
                            "自动保存会使用 macOS 版本记录，仍可恢复较早版本；手动模式会在关闭已修改文档前询问。"))
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)

                    Divider()
                        .padding(.vertical, 2)

                    Toggle(
                        tr("Automatically create a file for new drafts",
                           "自动为新草稿创建文件"),
                        isOn: Binding(
                            get: { autoSaveUntitled },
                            set: { requestToggleChange(.setAutoSaveUntitledDocuments($0)) }
                        )
                    )
                    .disabled(isChoosingUntitledDirectory)

                    HStack(spacing: 8) {
                        Text(untitledDirectory?.path(percentEncoded: false)
                             ?? tr("No folder selected", "尚未选择文件夹"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 285, alignment: .leading)
                        Button(tr("Choose…", "选择…")) {
                            chooseUntitledDirectory(committing: nil)
                        }
                    }
                    .padding(.leading, 20)
                    .disabled(!autoSaveUntitled)

                    Text(tr(
                        "After you stop typing, a nonblank Untitled document is saved here once. Later changes follow the save mode above.",
                        "停止输入后，非空白的未命名文档会在此首次落盘；后续修改遵循上方的保存模式。"
                    ))
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 380, alignment: .leading)
                    .padding(.leading, 20)

                    Divider()
                        .padding(.vertical, 2)

                    Toggle(
                        tr("Enable Quick Capture", "启用快速记录"),
                        isOn: Binding(
                            get: { quickCaptureEnabled },
                            set: { requestToggleChange(.setQuickCaptureEnabled($0)) }
                        )
                    )
                    .disabled(isChoosingUntitledDirectory)

                    Text(tr(
                        "Creates a new always-on-top draft from any app. Configure its global shortcut in Shortcuts settings.",
                        "可从任何应用新建置顶草稿；全局快捷键请在“快捷键”设置中配置。"
                    ))
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 380, alignment: .leading)
                    .padding(.leading, 20)
                }
            }

            GridRow {
                Text(tr("When document is changed by another application:", "文档被其他应用修改时："))
                    .gridCellColumns(2)
            }
            .padding(.bottom, -8)

            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Picker("", selection: $conflict) {
                    ForEach(AppSettings.ConflictResolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

        }
        .settingsPanePadding()
        .onAppear {
            untitledDirectory = AppSettings.untitledDocumentDirectoryURL()
            applyToggleState(GeneralSettingsTogglePolicy.normalized(
                toggleState,
                hasUntitledDirectory: untitledDirectory != nil
            ))
        }
    }

    private func intervalLabel(_ interval: DocumentAutoSaveInterval) -> String {
        let seconds = Int(interval.rawValue)
        return tr(seconds == 1 ? "1 second" : "\(seconds) seconds", "\(seconds) 秒")
    }

    private var toggleState: GeneralSettingsToggleState {
        GeneralSettingsToggleState(
            autoSaveUntitledDocuments: autoSaveUntitled,
            quickCaptureEnabled: quickCaptureEnabled
        )
    }

    private func requestToggleChange(_ intent: GeneralSettingsToggleIntent) {
        switch GeneralSettingsTogglePolicy.transition(
            from: toggleState,
            intent: intent,
            hasUntitledDirectory: untitledDirectory != nil
        ) {
        case .commit(let state):
            applyToggleState(state)
        case .chooseDirectory(let state):
            chooseUntitledDirectory(
                committing: state,
                replacing: toggleState
            )
        }
    }

    private func applyToggleState(_ state: GeneralSettingsToggleState) {
        let untitledChanged = autoSaveUntitled != state.autoSaveUntitledDocuments
        let quickCaptureChanged = quickCaptureEnabled != state.quickCaptureEnabled
        autoSaveUntitled = state.autoSaveUntitledDocuments
        quickCaptureEnabled = state.quickCaptureEnabled
        if untitledChanged {
            NotificationCenter.default.post(
                name: .untitledAutoSaveSettingsDidChange,
                object: nil
            )
        }
        if quickCaptureChanged {
            NotificationCenter.default.post(
                name: .quickCaptureSettingsDidChange,
                object: nil
            )
        }
    }

    private func chooseUntitledDirectory(
        committing proposedState: GeneralSettingsToggleState?,
        replacing originalState: GeneralSettingsToggleState? = nil
    ) {
        guard !isChoosingUntitledDirectory else { return }
        guard let settingsWindow = NSApplication.shared.keyWindow
                ?? NSApplication.shared.mainWindow else { return }
        isChoosingUntitledDirectory = true
        // Finish the SwiftUI control transaction before starting AppKit's sheet.
        // Starting a synchronous modal loop from @AppStorage.onChange can leave
        // the panel behind the Settings window and make the click look ignored.
        DispatchQueue.main.async {
            presentUntitledDirectoryPanel(
                for: settingsWindow,
                committing: proposedState,
                replacing: originalState
            )
        }
    }

    private func presentUntitledDirectoryPanel(
        for settingsWindow: NSWindow,
        committing proposedState: GeneralSettingsToggleState?,
        replacing originalState: GeneralSettingsToggleState?
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Choose", "选择")
        panel.message = tr(
            "Choose where FloralMD should create files for nonblank Untitled documents.",
            "选择 FloralMD 为非空白未命名文档创建文件的位置。"
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
        panel.beginSheetModal(for: settingsWindow) { response in
            isChoosingUntitledDirectory = false
            guard response == .OK, let url = panel.url else { return }
            do {
                try AppSettings.storeUntitledDocumentDirectory(url)
                untitledDirectory = url
                if let proposedState, let originalState {
                    applyToggleState(
                        GeneralSettingsTogglePolicy.completingDirectorySelection(
                            originalState: originalState,
                            proposedState: proposedState,
                            selectedDirectory: true
                        )
                    )
                } else {
                    NotificationCenter.default.post(
                        name: .untitledAutoSaveSettingsDidChange,
                        object: nil
                    )
                }
            } catch {
                settingsWindow.presentError(error)
            }
        }
    }
}

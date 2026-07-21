import SwiftUI

/// Global behaviour and presentation choices for the editing surface.
struct EditorSettingsView: View {
    @AppStorage(AppSettings.Key.interfaceLanguage) private var language = AppLanguage.system
    @AppStorage(AppSettings.Key.typewriterMode) private var typewriterMode = true
    @AppStorage(AppSettings.Key.sourceMode) private var sourceMode = false
    @AppStorage(AppSettings.Key.showMinimap) private var showMinimap = true
    @AppStorage(AppSettings.Key.imagePathStyle) private var imagePathStyle = AppSettings.ImagePathStyle.absolute
    @AppStorage(AppSettings.Key.imageAssetFolder) private var imageAssetFolder = "assets"

    private func tr(_ en: String, _ zh: String) -> String {
        AppCopy.text(en, zh, language: language)
    }

    var body: some View {
        SettingsPage(
            title: tr("Editor", "编辑器"),
            subtitle: tr(
                "Tune the editing experience without changing your Markdown source.",
                "调整编辑体验，不改变 Markdown 源文内容。"
            )
        ) {
            SettingsCard(tr("Editing", "编辑"), symbol: "text.cursor") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(tr("Typewriter scroll", "打字机滚动"), isOn: $typewriterMode)
                        .onChange(of: typewriterMode) {
                            EditorPreferenceCoordinator.setTypewriterMode(typewriterMode)
                        }
                    Text(tr("Keeps the insertion point vertically centred while typing.",
                            "输入时让插入点保持在窗口的垂直中央。"))
                        .settingsSupportingText()
                        .padding(.leading, 20)

                    Divider().padding(.vertical, 4)

                    HStack {
                        Text(tr("Image path", "图片路径"))
                        Spacer()
                        Picker("", selection: $imagePathStyle) {
                            ForEach(AppSettings.ImagePathStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    HStack {
                        Text(tr("Pasted image folder", "粘贴图片文件夹"))
                        Spacer()
                        TextField("assets", text: $imageAssetFolder)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                    Text(tr(
                        "The folder stays relative to each Markdown file. Absolute paths affect only the inserted link.",
                        "文件夹始终相对于当前 Markdown 文件；绝对路径选项只影响插入的链接。"
                    ))
                    .settingsSupportingText()
                }
            }

            SettingsCard(tr("Presentation", "显示"), symbol: "rectangle.on.rectangle") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(tr("Show source in editor", "在编辑器中显示源码"), isOn: $sourceMode)
                        .onChange(of: sourceMode) {
                            EditorPreferenceCoordinator.setSourceMode(sourceMode)
                        }
                    Toggle(tr("Show minimap", "显示缩略图"), isOn: $showMinimap)
                        .onChange(of: showMinimap) {
                            EditorPreferenceCoordinator.setShowMinimap(showMinimap)
                        }
                }
            }
        }
    }
}

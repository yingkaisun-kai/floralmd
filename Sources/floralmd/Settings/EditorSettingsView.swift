import SwiftUI

/// Global behaviour and presentation choices for the editing surface.
struct EditorSettingsView: View {
    @AppStorage(AppSettings.Key.interfaceLanguage) private var language = AppLanguage.system
    @AppStorage(AppSettings.Key.typewriterMode) private var typewriterMode = true
    @AppStorage(AppSettings.Key.sourceMode) private var sourceMode = false
    @AppStorage(AppSettings.Key.showMinimap) private var showMinimap = true

    private func tr(_ en: String, _ zh: String) -> String {
        AppCopy.text(en, zh, language: language)
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text(tr("Editing:", "编辑："))
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(tr("Typewriter scroll", "打字机滚动"), isOn: $typewriterMode)
                        .onChange(of: typewriterMode) {
                            EditorPreferenceCoordinator.setTypewriterMode(typewriterMode)
                        }
                    Text(tr("Keeps the insertion point vertically centred while typing.",
                            "输入时让插入点保持在窗口的垂直中央。"))
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360, alignment: .leading)
                        .padding(.leading, 20)
                }
            }

            GridRow { Divider().gridCellColumns(2) }

            GridRow {
                Text(tr("Presentation:", "显示："))
                    .gridColumnAlignment(.trailing)
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
        .settingsPanePadding()
    }
}

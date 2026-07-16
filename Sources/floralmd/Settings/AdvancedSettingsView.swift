import SwiftUI
import AppKit

struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Key.interfaceLanguage) private var language = AppLanguage.system
    @AppStorage(AppSettings.Key.blockExternalImages) private var blockExternalImages = true
    @AppStorage(AppSettings.Key.diagnosticLogging) private var diagnosticLogging = false
    @AppStorage(AppSettings.Key.verboseEditorDiagnostics) private var verboseEditorDiagnostics = false
    @AppStorage(AppSettings.Key.logRetention) private var logRetention = AppSettings.LogRetention.twoWeeks
    // Crash-log sending is dormant until the receiving server exists — the toggle
    // is hidden (commented out below) so it isn't offered with nowhere to send to.
    // Uncomment this and the "Crash reports:" GridRow once the server is live.
    // @AppStorage(AppSettings.Key.sendCrashLogs) private var sendCrashLogs = false
    @State private var showingWarnings = false
    private func tr(_ en: String, _ zh: String) -> String { AppCopy.text(en, zh, language: language) }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text(tr("Privacy & Security:", "隐私与安全："))
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(tr("Block external images", "阻止外部图片"), isOn: $blockExternalImages)
                        .onChange(of: blockExternalImages) { refreshOpenReadViews() }
                    Text(tr("For more information, refer to this [proposal](https://github.com/opencloud-eu/opencloud/issues/1145).",
                            "更多信息请参阅此[提案](https://github.com/opencloud-eu/opencloud/issues/1145)。"))
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                        
                    // TODO: Add a "Enable HTTP whitelist" toggle here
                    // with a short scrollable view of the whitelist that allows user addition
                    // with +/- signs at the bottom-right corner
                    // Implement later
                }
            }

            GridRow {
                Divider().gridCellColumns(2)
            }

            GridRow {
                Text(tr("Diagnostics:", "诊断："))
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(tr("Save diagnostic logs", "保存诊断日志"), isOn: $diagnosticLogging)
                        .onChange(of: diagnosticLogging) { AppSettings.applyLogging() }
                    HStack(spacing: 6) {
                        Text(tr("Clear logs after:", "日志保留时间："))
                        Picker("", selection: $logRetention) {
                            ForEach(AppSettings.LogRetention.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: logRetention) { AppSettings.applyLogging() }
                    }
                    .disabled(!diagnosticLogging)
                    .padding(.leading, 20)
                    Text(tr("Logs are kept locally at \(AppSettings.logDirectory.path(percentEncoded: false)) and will never leave that folder unless you move them. They are only useful if you want to improve your bug reports / GitHub issues.",
                            "日志仅保存在本机 \(AppSettings.logDirectory.path(percentEncoded: false))，除非你主动移动，否则不会离开该目录。它们仅用于完善错误报告或 GitHub Issue。"))
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                    Toggle(tr("Verbose editor tracing", "详细编辑器追踪"), isOn: $verboseEditorDiagnostics)
                        .onChange(of: verboseEditorDiagnostics) { AppSettings.applyLogging() }
                        .disabled(!diagnosticLogging)
                        .padding(.leading, 20)
                    Text(tr("Records every keystroke, caret move, and sync — for reproducing tricky editor bugs (caret drift). Noisy; leave off unless asked.",
                            "记录每次按键、光标移动和同步，用于复现复杂的编辑器问题（如光标漂移）。日志量较大，除非排障需要，否则请保持关闭。"))
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360, alignment: .leading)
                        .padding(.leading, 40)
}
            }

            // Dormant until the crash-report server exists (see note above and
            // CrashReporter). The launch-time upload path and the `sendCrashLogs`
            // setting stay in place but inert (default off); only this UI is hidden.
            // GridRow {
            //     Text("Crash reports:")
            //         .gridColumnAlignment(.trailing)
            //     VStack(alignment: .leading, spacing: 6) {
            //         Toggle("Automatically send crash logs", isOn: $sendCrashLogs)
            //         Text("Crash logs are sent only to us and will be used and stored for crash fix purposes only.")
            //             .foregroundStyle(.secondary)
            //             .controlSize(.small)
            //             .fixedSize(horizontal: false, vertical: true)
            //             .frame(width: 380, alignment: .leading)
            //             .padding(.leading, 20)
            //     }
            // }

            GridRow {
                Text(tr("Dialog warnings:", "对话框警告："))
                    .gridColumnAlignment(.trailing)
                Button(tr("Manage Warnings…", "管理警告…")) { showingWarnings = true }
            }
        }
        .settingsPanePadding()
        .sheet(isPresented: $showingWarnings) {
            ManageWarningsView()
        }
    }

    /// Pushes the toggle to every open document's editor (Edit mode's inline
    /// image overlay) and Read view, so the change takes effect immediately.
    private func refreshOpenReadViews() {
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.allowRemoteImages = !blockExternalImages
            document.refreshReadView()
        }
    }
}

/// The Manage Warnings sheet: per-warning suppression toggles.
private struct ManageWarningsView: View {
    @AppStorage(AppSettings.Key.interfaceLanguage) private var language = AppLanguage.system
    @AppStorage(AppSettings.Key.suppressInconsistentLineEndingWarning)
    private var suppressLineEnding = false
    @Environment(\.dismiss) private var dismiss
    private func tr(_ en: String, _ zh: String) -> String { AppCopy.text(en, zh, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Suppress the following warnings:", "不再显示以下警告："))
            Toggle(tr("Inconsistent line endings", "换行符不一致"), isOn: $suppressLineEnding)
            HStack {
                Spacer()
                Button(tr("Done", "完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .scenePadding()
        .frame(width: 360)
    }
}

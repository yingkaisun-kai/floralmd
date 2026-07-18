// Modified from Edmund by Yingkai Sun for FloralMD.
// Note: `swift run` does not bundle resources, so the app icon and version
// string will not render correctly. Build and launch via the Debug app bundle.
import SwiftUI
import AppKit

struct AboutView: View {
    @AppStorage(AppSettings.Key.interfaceLanguage) private var language = AppLanguage.system.rawValue

    private func tr(_ english: String, _ chinese: String) -> String {
        AppCopy.text(english, chinese, language: AppLanguage(rawValue: language) ?? .system)
    }

    var body: some View {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.bottom, 4)

            Text(AppIdentity.displayName)
                .font(.title2.weight(.semibold))

            Text(tr("Version \(short) (\(build))", "版本 \(short)（\(build)）"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Copyright \u{00A9} 2026 Yingkai Sun")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link("GitHub", destination: URL(string: "https://github.com/yingkaisun-kai/floralmd")!)
                    .focusEffectDisabled()
                Link(tr("License", "许可证"), destination: URL(string: "https://github.com/yingkaisun-kai/floralmd/blob/main/LICENSE")!)
                    .focusEffectDisabled()
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 280)
    }
}

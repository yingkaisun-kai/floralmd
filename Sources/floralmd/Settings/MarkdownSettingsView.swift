// Modified from Edmund by Yingkai Sun for FloralMD.
import SwiftUI

/// Per-extension Markdown controls. Every `@AppStorage` property belongs to
/// this long-lived hosted view; the settings controller caches it so switching
/// panes never recreates active controls or loses editing identity.
struct MarkdownSettingsView: View {
    @AppStorage(AppSettings.Key.interfaceLanguage) private var language = AppLanguage.system
    @AppStorage(AppSettings.Key.markdownHighlight) private var highlight = true
    @AppStorage(AppSettings.Key.markdownInlineComment) private var inlineComment = true
    @AppStorage(AppSettings.Key.markdownCallout) private var callout = true
    @AppStorage(AppSettings.Key.markdownObsidianCallouts) private var obsidianCallouts = true
    @AppStorage(AppSettings.Key.markdownCollapsibleCallout) private var collapsibleCallout = true
    @AppStorage(AppSettings.Key.markdownWikilink) private var wikilink = true
    @AppStorage(AppSettings.Key.markdownWikilinkEmbed) private var wikilinkEmbed = true
    @AppStorage(AppSettings.Key.markdownFootnote) private var footnote = true
    @AppStorage(AppSettings.Key.markdownMath) private var math = true
    @AppStorage(AppSettings.Key.markdownFrontMatter) private var frontMatter = true
    @AppStorage(AppSettings.Key.markdownTag) private var tag = true
    @AppStorage(AppSettings.Key.markdownBlockID) private var blockID = true
    @AppStorage(AppSettings.Key.markdownImageDimensions) private var imageDimensions = true
    @AppStorage(AppSettings.Key.markdownMultiBlockComment) private var multiBlockComment = true

    private func tr(_ en: String, _ zh: String) -> String {
        AppCopy.text(en, zh, language: language)
    }

    var body: some View {
        SettingsPage(
            title: "Markdown",
            subtitle: tr(
                "Choose which extensions FloralMD recognizes in Edit and Read. Disabling one leaves its source literal.",
                "选择 FloralMD 在编辑与阅读模式中识别的扩展；关闭后源码保持原样显示。"
            )
        ) {
            SettingsCard(tr("GitHub-compatible", "GitHub 兼容"), symbol: "checkmark.seal") {
                VStack(alignment: .leading, spacing: 10) {
                    featureToggle(tr("Callouts", "提示块"), $callout)
                    Text(tr("The five GitHub alert types remain separate from Obsidian-only aliases.",
                            "GitHub 的五种提示块与 Obsidian 专属类型分别控制。"))
                        .settingsSupportingText().padding(.leading, 20)
                }
            }

            SettingsCard(tr("Obsidian syntax", "Obsidian 语法"), symbol: "note.text") {
                VStack(alignment: .leading, spacing: 10) {
                    featureToggle(tr("Obsidian callout types", "Obsidian 提示块类型"), $obsidianCallouts)
                    featureToggle(tr("Collapsible callouts", "可折叠提示块"), $collapsibleCallout)
                    featureToggle(tr("Wiki links", "Wiki 链接"), $wikilink)
                    featureToggle(tr("Wiki embeds", "Wiki 嵌入标签"), $wikilinkEmbed)
                    featureToggle(tr("Tags", "标签"), $tag)
                    featureToggle(tr("Block IDs", "块 ID"), $blockID)
                    featureToggle(tr("Inline comments", "行内注释"), $inlineComment)
                    featureToggle(tr("Multi-block comments", "多块注释"), $multiBlockComment)
                    featureToggle(tr("YAML front matter", "YAML 前置元数据"), $frontMatter)
                }
            }

            SettingsCard(tr("Additional syntax", "其他语法"), symbol: "textformat") {
                VStack(alignment: .leading, spacing: 10) {
                    featureToggle(tr("Highlights", "高亮"), $highlight)
                    featureToggle(tr("Footnotes", "脚注"), $footnote)
                    featureToggle(tr("Math", "数学公式"), $math)
                    featureToggle(tr("Image dimensions", "图片尺寸"), $imageDimensions)
                }
            }
        }
    }

    private func featureToggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(label, isOn: binding)
            .onChange(of: binding.wrappedValue) {
                EditorPreferenceCoordinator.refreshMarkdownFeatures()
            }
    }
}

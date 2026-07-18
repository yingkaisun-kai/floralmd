<!-- Modified from Edmund by Yingkai Sun for FloralMD. -->
# FloralMD

![macOS Version Compatibility](https://img.shields.io/badge/platform-macOS%2014.0%2B-0064e1?style=flat-square&color=0064e1)
![GitHub License](https://img.shields.io/github/license/yingkaisun-kai/floralmd?style=flat-square&color=772678)
![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/yingkaisun-kai/floralmd/total?style=flat-square&color=ff6916)
![FloralMD App Icon](docs/assets/AppIcon/AppIcon_16x16.png)

![FloralMD native Markdown editor with comparison matrix and translucent floating note](docs/assets/floralmd-poster.png)

[中文](#中文) · [English](#english)

## 中文

FloralMD（Floral + Markdown）是一款面向 macOS 的原生、文件优先 Markdown
编辑器。它允许你直接打开任意位置的 `.md` 文件，在同一个窗口中通过标签页处理
多个文档，并获得接近 Obsidian、Typora 的行内实时渲染体验——但不要求先创建或
打开一个文件夹，也不要求把文档迁移进特定的知识库。

### 为什么做 FloralMD

我一直希望 macOS 上有一款足够原生、轻量，又能直接编辑和渲染 Markdown 的工具。
Obsidian 很强大，但它以文件夹和 Vault 为中心：当我只是想打开散落在不同位置的
单个 Markdown 文件时，这种使用方式会带来不必要的上下文和组织负担。

FloralMD 围绕这种单文件工作方式设计：强调任意文件打开、单文件阅读与编辑、多标签、
文档大纲、附近文件导航，以及 Finder 中的 Markdown 预览。它不试图取代完整的知识库，
而是让一个普通 Markdown 文件在 macOS 上也能获得自然、完整的使用体验。

### 为什么叫 FloralMD

每一个 Markdown 文件都可以像一片独立的花瓣：它不必先属于某个 Vault，也不必被
放进规定的目录才能打开。需要时，来自不同位置的文件又可以在同一个窗口中并列展开，
共同组成一次完整的工作现场。现有花瓣图标保留了这个“单个文件”的意象。

“Floral”把视角从单片花瓣扩展到完整的花卉意象，也代表这款工具希望保持的气质：
轻量、自然、安静，专注于内容本身。`MD` 则明确了它所服务的文件格式，因此得名
**FloralMD**。

### 主要特点

完整的当前功能列表见 [FloralMD 功能说明](docs/FEATURES.md)。

- **直接打开文件**：从 Finder 或应用中打开任意 `.md` 文件，无需 Vault。
- **行内实时渲染**：提供接近 Typora、Obsidian 的所见即所得编辑体验。
- **多文档标签页**：不同目录中的 Markdown 文件可以出现在同一窗口中。
- **单文件导航**：左侧大纲聚焦当前文档，右侧文件栏用于浏览附近文件和已打开文档。
- **语义缩略图**：用标题、列表、代码和 Git 改动色块概览长文档，并可单击或拖动滚动。
- **Finder Quick Look**：在 Finder 中选中文件并按空格，直接查看 FloralMD 风格的渲染结果。
- **悬浮便签**：窗口可置顶并使用半透明背景；快速记录可从任何应用唤起置顶草稿。
- **原生 macOS**：使用 Swift、AppKit 和 TextKit 2 构建，不依赖 Electron。
- **本地优先**：默认离线工作，并可阻止外部图片和不安全的 HTML 内容。
- **Markdown 扩展**：支持数学公式、Callout、Wiki Link 等常用语法。

### 一眼看懂 FloralMD 的不同

**像普通文件一样随处打开，像现代编辑器一样实时渲染，也能像便签一样悬浮在桌面上。**

| 工具 | 无需 Vault | 行内实时渲染 | 悬浮便签 | Finder Quick Look | Git 改动提示 | macOS 专属原生 | 开源 |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **FloralMD** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| [Typora](https://typora.io/) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [Obsidian](https://obsidian.md/) | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ |
| [MarkText](https://github.com/marktext/marktext) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |

`✅` 表示官方内置能力；`❌` 不代表无法通过插件或外部工具实现。对比依据截至
2026-07-16。“悬浮便签”指置顶、半透明背景与快速记录组成的完整工作流；
“macOS 专属原生”不包括仅提供 Mac 版本的跨平台应用。查看
[详细对比、判定口径与资料来源](docs/MARKDOWN_EDITOR_COMPARISON.md)。

### 安装

从 [Releases](https://github.com/yingkaisun-kai/floralmd/releases/latest) 下载
`FloralMD.dmg`，打开后将 `FloralMD.app` 拖入“应用程序”文件夹。

如果 macOS 无法验证开发者，请先尝试打开一次 FloralMD，再前往“系统设置 →
隐私与安全性”，找到被阻止的 FloralMD 并选择“仍要打开”。请只对从本项目官方
GitHub Release 下载的安装包执行此操作。

FloralMD 目前仅使用临时签名，尚未使用 Apple Developer ID 签名或经过 Apple
公证。正式版使用 FloralMD 专用 EdDSA 密钥和独立发布 feed 提供 Sparkle 更新，
并包含标准“检查更新…”入口。
本地 Debug 构建保持完全隔离，不链接或暴露生产更新器。

### 本地构建

需要 macOS 14 或更高版本，以及完整安装的 Xcode：

```bash
swift build
swift test
./scripts/build-app.sh
```

本地构建默认生成身份完全隔离的 `build/FloralMD-Debug.app`，应直接在构建目录运行，
不要复制成 `/Applications/FloralMD.app`。调试 Finder Quick Look 时使用
`./scripts/build-app.sh --with-quick-look`；该扩展也使用独立 Debug 身份。
日常使用的正式版只能从 GitHub Release DMG 安装。

### 核心依赖

- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [SwiftMath](https://github.com/mgriebling/SwiftMath)
- [Sparkle](https://github.com/sparkle-project/Sparkle)

## English

FloralMD is a native, file-first Markdown editor for macOS. It opens `.md` files
from anywhere, keeps documents from different folders together as window tabs,
and provides inline live rendering without requiring a vault or a dedicated
workspace folder.

### Why FloralMD

I wanted a Markdown experience on macOS that felt native and lightweight while
still rendering the document as I edited it. Obsidian is powerful, but its
folder- and vault-centered workflow feels unnecessarily heavy when I only want
to open an individual Markdown file stored somewhere on my Mac.

FloralMD is designed around that single-file workflow: arbitrary-file opening,
focused reading and editing, window tabs, document outlines, nearby-file
navigation, and Finder previews. It does not try to replace a full knowledge
base; it gives an ordinary Markdown file a complete, natural home on macOS.

### Why the name FloralMD

Each Markdown file can be its own petal. It does not need to belong to a vault
or live inside a prescribed folder before it can be opened. When useful, files
from different locations can still come together in one window and form a
complete working context. The existing petal icon preserves that single-file
idea.

“Floral” broadens the image from one petal to the larger floral whole while
keeping the app's intended character: light, natural, quiet, and focused on the
document itself. `MD` makes its purpose explicit—hence **FloralMD**.

### Highlights

See [FloralMD Features](docs/FEATURES.md) for the complete current feature list.

- **Open any file**: Open `.md` files directly from Finder or the app—no vault required.
- **Inline live rendering**: A Typora- and Obsidian-like editing experience.
- **Window tabs**: Keep Markdown files from different folders in one window.
- **Document-first navigation**: A left outline for the current document and a right sidebar for nearby and open files.
- **Semantic minimap**: Scan headings, lists, code, and Git changes in long documents, then click or drag to scroll.
- **Finder Quick Look**: Select a Markdown file and press Space for a FloralMD-rendered preview.
- **Floating notes**: Pin a translucent document above other apps, or summon an always-on-top draft with Quick Capture.
- **Native macOS**: Built with Swift, AppKit, and TextKit 2 rather than Electron.
- **Local first**: Works offline by default, with controls for external images and unsafe HTML.
- **Markdown extensions**: Supports math, callouts, wiki links, and other practical syntax.

### FloralMD at a glance

**Open Markdown anywhere, edit with live rendering, or keep it floating like a desktop note.**

| Tool | No vault required | Inline live rendering | Floating notes | Finder Quick Look | Git change cues | Mac-native only | Open source |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **FloralMD** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| [Typora](https://typora.io/) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [Obsidian](https://obsidian.md/) | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ |
| [MarkText](https://github.com/marktext/marktext) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |

`✅` means built into the official product; `❌` does not mean a plugin or
external tool cannot provide it. Compared using public information available on
2026-07-16. “Floating notes” means the complete combination of always-on-top
windows, a translucent background, and Quick Capture. “Mac-native only”
excludes cross-platform products that also ship a Mac version. Read the
[detailed comparison, criteria, and sources](docs/MARKDOWN_EDITOR_COMPARISON.md#english).

### Installation

Download `FloralMD.dmg` from the
[latest release](https://github.com/yingkaisun-kai/floralmd/releases/latest), open
it, and drag `FloralMD.app` into Applications.

If macOS cannot verify the developer, try to open FloralMD once, then open
System Settings → Privacy & Security and choose **Open Anyway** for the blocked
app. Only do this for an installer downloaded from this project's official
GitHub Release.

FloralMD currently uses an ad-hoc signature and is not yet signed with an Apple
Developer ID or notarized by Apple. Production releases use
Sparkle with a FloralMD-specific EdDSA key and dedicated release feed, including
the standard **Check for Updates…** command. Local Debug builds remain fully
isolated and do not link or expose the production updater.

### Build locally

FloralMD requires macOS 14 or later and a full Xcode installation:

```bash
swift build
swift test
./scripts/build-app.sh
```

Local builds create the fully isolated `build/FloralMD-Debug.app` and should run
in place, never be copied to `/Applications/FloralMD.app`. Use
`./scripts/build-app.sh --with-quick-look` only when debugging the independently
identified Finder Quick Look extension. Install the production app only from a
GitHub Release DMG.

### Core dependencies

- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [SwiftMath](https://github.com/mgriebling/SwiftMath)
- [Sparkle](https://github.com/sparkle-project/Sparkle)

## License

[Apache License 2.0](LICENSE). Upstream attribution and modification context are
recorded in [NOTICE](NOTICE). Vendored asset licenses are kept in
[LICENSES](LICENSES/); applicable SwiftPM dependency license texts are copied
from the resolved packages into the app bundle at build time.

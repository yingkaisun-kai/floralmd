# FloralMD 与其他 Markdown 工具

README 中的矩阵用于快速说明 FloralMD 的产品位置；本文保留更完整的比较、判定口径与
资料来源。它不是“谁在所有场景下都最好”的排名，而是帮助用户判断哪种工作流更适合自己。

信息依据各项目截至 2026-07-16 的官方公开说明整理。

## 判定口径

- `✅` 表示该能力由官方产品直接提供。
- `❌` 表示没有被列为官方内置能力，不代表插件、扩展或外部工具无法实现。
- “行内实时渲染”指在同一个编辑视图中呈现格式效果，而不是另开预览窗格。
- “悬浮便签”指同时提供窗口置顶、半透明背景和从其他应用快速新建草稿的工作流；
  只有单独的置顶命令不计为完整支持。
- “内置 Git 改动提示”指编辑器本身能在文档导航或缩略视图中提示改动，不包括另装插件。
- “macOS 专属原生”指产品只面向 macOS，并以系统原生窗口与交互为主要界面；
  仅提供 macOS 安装包的跨平台产品不计入。
- “开源”只判断应用主体是否使用开源许可证，不判断插件 API 或周边工具。

## 功能矩阵

| 工具 | 无需 Vault | 行内实时渲染 | 悬浮便签 | Finder Quick Look | Git 改动提示 | macOS 专属原生 | 开源 |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **FloralMD** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| [Typora](https://typora.io/) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [Obsidian](https://obsidian.md/) | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ |
| [MarkText](https://github.com/marktext/marktext) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |

## 每款工具的取向

### FloralMD

FloralMD 面向原生 macOS 的文件优先工作流。它可以直接打开任意位置的 Markdown 文件，
把不同目录的文档放进同一个原生标签窗口，并提供行内实时渲染、源码模式和阅读模式。
Finder Quick Look 扩展让用户无需启动应用即可按空格预览；编辑器内的大纲、附近文件、
语义缩略图和 Git 改动提示则服务于单个文档的阅读与修改。普通文档可以独立置顶；
置顶时窗口采用 88% 不透明的背景，而文字、光标和图片保持清晰。快速记录还能从任何
应用唤起一个置顶草稿，并沿用普通 Markdown 文件的自动落盘流程，因此可以直接作为
桌面便签使用。

### Typora

Typora 同样适合直接打开普通 Markdown 文件，并以成熟的所见即所得编辑和丰富导出见长。
它在 macOS 上接入了系统文档能力，但官方明确说明目前不提供 Quick Look 插件，并建议
使用 QLMarkdown 或 Glance。Typora 自身支持 Always On Top，但官方功能说明没有列出
半透明窗口与跨应用快速记录组成的完整便签工作流。Typora 采用付费授权，不是开源应用。

### Obsidian

Obsidian 的优势是知识库、双向链接和插件生态。它提供 Live Preview、源码和阅读视图，
但文件工作流围绕已注册的 Vault 展开：即使通过绝对路径打开文件，也会寻找包含该文件
的 Vault。Git 等能力可以通过社区插件补充，但不属于这里比较的官方内置能力。

### MarkEdit

MarkEdit 是 macOS 上轻量、开源的 Markdown 源码编辑器，强调类似 TextEdit 的直接文件
体验和小体积，系统控件也遵循 macOS 原生外观与行为。它同样包含 Finder Quick Look
扩展；核心编辑器基于 CodeMirror 6，编辑预览使用独立预览窗格，而不是同一编辑视图
中的行内实时渲染。

### MarkText

MarkText 是跨 macOS、Windows 和 Linux 的开源 Markdown 编辑器，提供实时预览、
所见即所得、源码、打字机和专注模式。它适合需要跨平台一致体验的用户；官方核心说明
没有列出 Finder Quick Look 或内置 Git 改动提示。

## 如何选择

- 想直接打开散落在 Mac 各处的文件，同时需要行内渲染、悬浮便签、Quick Look 和
  Git 视觉提示：选择 **FloralMD**。
- 更看重成熟写作与导出：选择 **Typora**。
- 主要维护双向链接知识库并依赖插件生态：选择 **Obsidian**。
- 想要极简、开源的 macOS Markdown 源码编辑器：选择 **MarkEdit**。
- 需要跨平台、开源的所见即所得编辑：选择 **MarkText**。

## 资料来源

- FloralMD：[功能说明](FEATURES.md)、[项目许可证](../LICENSE)
- Typora：[Quick Start](https://support.typora.io/Quick-Start/)、[Typora on macOS](https://support.typora.io/Typora-on-macOS/)、[Always On Top](https://support.typora.io/Shortcut-Keys/)、[购买与授权](https://support.typora.io/purchase/)
- Obsidian：[Live Preview](https://help.obsidian.md/Live+preview+update)、[Obsidian URI](https://help.obsidian.md/Extending+Obsidian/Obsidian+URI)、[官方发布仓库](https://github.com/obsidianmd/obsidian-releases)
- MarkEdit：[官方仓库与 README](https://github.com/MarkEdit-app/MarkEdit)
- MarkText：[官方仓库与 README](https://github.com/marktext/marktext)

---

## English

The README matrix gives a quick view of FloralMD's product position. This page
keeps the fuller comparison, criteria, and sources. It is not a ranking of which
tool is best in every situation; it helps readers identify the workflow that
fits them.

The comparison uses official public information available on 2026-07-16.

### Criteria

- `✅` means the capability is provided directly by the official product.
- `❌` means it is not listed as built in; a plugin, extension, or external tool
  may still provide it.
- “Inline live rendering” means formatting appears in the editing view itself,
  rather than in a separate preview pane.
- “Floating notes” requires the complete workflow: always-on-top windows, a
  translucent background, and quick draft creation from another app. A pin
  command alone does not count as full support.
- “Built-in Git change cues” means the editor itself shows changes in document
  navigation or a minimap, without an additional plugin.
- “Mac-native only” means the product targets macOS exclusively and uses native
  system windows and interactions as its primary interface. A cross-platform
  product with a Mac build does not count.
- “Open source” describes the main application, not its plugin API or companion
  tools.

### Feature matrix

| Tool | No vault required | Inline live rendering | Floating notes | Finder Quick Look | Git change cues | Mac-native only | Open source |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **FloralMD** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| [Typora](https://typora.io/) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [Obsidian](https://obsidian.md/) | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ |
| [MarkText](https://github.com/marktext/marktext) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |

### Product directions

#### FloralMD

FloralMD is built for a native, file-first macOS workflow. It opens Markdown
files from anywhere, combines documents from different folders in one native
tabbed window, and provides inline live rendering, source mode, and read mode.
Its Finder Quick Look extension previews files without launching the app, while
the outline, nearby files, semantic minimap, and Git change cues support focused
reading and editing of individual documents. Any document can be pinned above
other apps; pinned windows use an 88%-opaque background while keeping text,
carets, and images crisp. Quick Capture can summon an always-on-top draft from
another app and reuse the normal Markdown autosave flow, so FloralMD can serve
as a desktop note.

#### Typora

Typora also works well with ordinary Markdown files and is known for mature
WYSIWYG editing and extensive export. It integrates with macOS document
features, but its official documentation explicitly says it does not currently
provide a Quick Look plugin and recommends QLMarkdown or Glance instead. Typora
does provide an Always On Top command, but its official feature descriptions do
not list the full combination of translucent windows and cross-app quick
capture used by this comparison. Typora uses a paid proprietary license.

#### Obsidian

Obsidian's strengths are knowledge bases, backlinks, and its plugin ecosystem.
It provides Live Preview, source, and reading views, but its file workflow is
organized around registered vaults: opening an absolute path searches for the
most specific vault containing that file. Git functionality can be added with
community plugins, but it is not treated as a built-in capability here.

#### MarkEdit

MarkEdit is a lightweight, open-source Markdown source editor for macOS, with a
direct-file experience inspired by TextEdit and a very small application
footprint. Its system controls follow native macOS appearance and behavior. It
also includes a Finder Quick Look extension. Its core editor uses CodeMirror 6,
with editing preview provided in a separate pane rather than as inline
rendering in the editing view.

#### MarkText

MarkText is an open-source editor for macOS, Windows, and Linux. It provides
real-time preview, WYSIWYG, source, typewriter, and focus modes. It suits users
who need a consistent cross-platform experience; its official core description
does not list Finder Quick Look or built-in Git change cues.

### Which one fits?

- For files anywhere on a Mac plus inline rendering, floating notes, Quick Look,
  and Git visual cues: choose **FloralMD**.
- For mature writing and export: choose **Typora**.
- For a backlink-centered knowledge base and plugin ecosystem: choose
  **Obsidian**.
- For a minimal, open-source macOS Markdown source editor: choose **MarkEdit**.
- For cross-platform, open-source WYSIWYG editing: choose **MarkText**.

### Sources

- FloralMD: [feature reference](FEATURES.md), [project license](../LICENSE)
- Typora: [Quick Start](https://support.typora.io/Quick-Start/), [Typora on macOS](https://support.typora.io/Typora-on-macOS/), [Always On Top](https://support.typora.io/Shortcut-Keys/), [purchase and licensing](https://support.typora.io/purchase/)
- Obsidian: [Live Preview](https://help.obsidian.md/Live+preview+update), [Obsidian URI](https://help.obsidian.md/Extending+Obsidian/Obsidian+URI), [official releases repository](https://github.com/obsidianmd/obsidian-releases)
- MarkEdit: [official repository and README](https://github.com/MarkEdit-app/MarkEdit)
- MarkText: [official repository and README](https://github.com/marktext/marktext)

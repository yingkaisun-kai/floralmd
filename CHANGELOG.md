<!-- Modified from Edmund by Yingkai Sun for FloralMD. -->
# FloralMD Changelog

All notable changes will be documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). FloralMD uses
calendar versions in `YYYY.MM.PATCH` form beginning with `2026.7.0`; earlier
`0.x` versions are retained as pre-CalVer history.

CalVer sections use one bilingual structure: a complete `### 中文` block comes
first, with `#### 新增` / `#### 变更` / `#### 修复` categories as needed; a
complete `### English` block follows, using the corresponding Keep a Changelog
categories. Language is never marked with inline bold labels.

## [2026.7.7] — 2026-07-20

### 中文

#### 新增
- 数字设置项现在可以单独恢复默认值。

#### 修复
- 修复表格宽度不随正文列宽继续扩展、开放式边框不一致、单元格多行文字过挤，
  以及阅读模式默认表头未左对齐的问题。
- 修复未命名文档在输入后清空时仍被视为未保存修改，并在关闭窗口或退出应用时
  错误询问是否保存的问题。
- 修复高行距下光标高度异常、文末空行位置延迟跳动，以及中文输入法组合期间
  光标没有跟随拼音输入位置的问题。

### English

#### Added
- Numeric settings can now be restored to their defaults individually.

#### Fixed
- Fixed tables stopping short of the reading-column width, inconsistent open
  borders, cramped multiline cells, and default table headers not being
  left-aligned in Read mode.
- Fixed cleared untitled documents remaining marked as unsaved and prompting
  to save when closing the window or quitting the app.
- Fixed oversized carets with custom line spacing, terminal empty-line carets
  jumping only after typing, and the caret not following the active position
  during Chinese input-method composition.

## [2026.7.6] — 2026-07-18

### 中文

#### 新增
- 文件侧栏新增符合 macOS 习惯的右键菜单，可打开或重命名 Markdown 文件、在 Finder
  中显示文件与文件夹、复制路径，并在安全处理未保存标签后将文件移到废纸篓。

#### 修复
- 修复打开第二个文件并出现原生标签栏后，左上角大纲按钮被标签栏压住的问题。

### English

#### Added
- Added a macOS-style file-sidebar context menu for opening and renaming Markdown files,
  revealing files and folders in Finder, copying paths, and safely moving files to the Trash
  after reviewing unsaved tabs.

#### Fixed
- Fixed the outline button being clipped by the native tab bar after opening a second file.

## [2026.7.5] — 2026-07-18

### 中文

#### 变更
- 扩大阅读模式中标题与列表项的垂直间距，让长文档的层级和段落节奏更清晰。

#### 修复
- 修复部分正式版在首次显示公式时可能意外退出的问题。
- 修复斜体公式字形右缘被裁切、较高的行内公式与下一段重叠，以及列表项中的块公式无法正确缩进和预留高度的问题。
- 修复代码中的 `$$…$$` 被误渲染成公式，以及阅读模式中夹在正文里的 `$$…$$` 会替换整段内容的问题。
- 修复在编辑与阅读模式之间切换时丢失阅读位置，或短暂显示旧滚动位置后再跳动的问题。
- 修复 Finder Quick Look 预览未按打开时的系统浅色或深色外观显示的问题。

### English

#### Changed
- Increased heading and list-item spacing in Read mode for clearer hierarchy and document rhythm.

#### Fixed
- Fixed some production builds quitting when displaying math for the first time.
- Fixed clipped italic math glyphs, tall inline equations overlapping the next paragraph, and list-item display math losing its indent or vertical space.
- Fixed `$$…$$` inside code rendering as math and embedded display math replacing the surrounding prose in Read mode.
- Fixed Edit/Read mode switches losing the reading position or briefly showing a stale scroll position before jumping.
- Fixed Finder Quick Look previews not matching the system light or dark appearance when opened.

## [2026.7.4] — 2026-07-17

### 中文

#### 变更
- 重新整理窗口、标题栏、文件侧边栏与大纲的视觉层级，使用更明亮、稳定的冷中性色表面和更清晰的分隔线；设置窗口现在采用固定分类侧栏与可滚动卡片布局，切换分类和调整窗口大小更加稳定。

#### 修复
- 修复“所有 Space”模式无法可靠进入其他 App 原生全屏 Space 的问题；置顶文档现在使用可复用的辅助面板承载原有编辑内容，并保持窗口位置、标签页、选区、撤销和输入法状态。
- 修复在“所有 Space”模式下从文件侧边栏连续打开多个标签页时可能出现的停顿和空白过渡；新标签页现在会增量接入并提前准备，已有标签页不会重复重建。
- 修复应用图标圆角外区域在 Finder、Quick Look 和 DMG 中显示为不透明方块的问题，并在构建时校验透明通道。

### English

#### Changed
- Refined the visual hierarchy across the window, titlebar, file sidebar,
  and outline with brighter, stable cool-neutral surfaces and clearer
  separators. Settings now uses a fixed category sidebar with scrollable
  cards, keeping category changes and window resizing stable.

#### Fixed
- Fixed All Spaces mode failing to reliably appear in other apps' native
  full-screen Spaces. Pinned documents now use reusable auxiliary panels that
  retain the existing editor content, window position, tabs, selection, undo,
  and input-method state.
- Fixed pauses and blank transitions when opening several sidebar files as
  tabs in All Spaces mode. New tabs now join incrementally and prewarm without
  rebuilding existing tabs.
- Fixed the area outside the app icon's rounded shape appearing as an opaque
  square in Finder, Quick Look, and DMGs, with alpha-channel validation added
  to the build.

## [2026.7.3] — 2026-07-17

### 中文

#### 新增
- 窗口置顶现在提供“不置顶”“仅当前 Space”和“所有 Space”三种会话模式，标题栏会常驻显示当前状态；“所有 Space”会跟随普通桌面 Space，并尽力加入其他 App 的原生全屏 Space 与 Stage Manager 集合，在 FloralMD 自身全屏结束后恢复。

#### 修复
- 修复点击不同段落或触发正文重新排版时，部分可见文字可能瞬时消失的问题；编辑器现在会在布局失效后立即重建受影响的可见 TextKit 2 片段。

### English

#### Added
- Window pinning now has three session modes with an always-visible titlebar
  status: Off, Current Space, and All Spaces. All Spaces follows the window
  across desktop Spaces and is eligible to join other apps'
  native full-screen Spaces and Stage Manager sets, then restores after
  FloralMD exits its own full screen.

#### Fixed
- Fixed visible text briefly disappearing when clicking between blocks or
  triggering document reflow. The editor now rebuilds affected visible
  TextKit 2 fragments immediately after invalidating their layout.

## [2026.7.2] — 2026-07-16

### 中文

#### 修复
- 修复语义缩略图与正文位置不一致的问题：短文档不再被纵向铺满，长文档只在超出可用高度后压缩，自动换行内容、Git 标记、光标、视口与点击拖动现在使用同一套源码坐标。

### English

#### Fixed
- Fixed the semantic minimap drifting from the document: short files no longer stretch to fill its height, long files compress only when needed, and wrapped content, Git markers, the caret, viewport, clicks, and drags now share one source-based coordinate model.

## [2026.7.1] — 2026-07-16

### 中文

#### 新增
- 所有置顶文档窗口现在会使用固定的半透明背景，同时保持文字、光标、控件、图片和公式清晰不变；取消置顶、进入全屏或启用系统“减少透明度”与“增强对比度”时会自动恢复不透明背景。
- 新增统一的快捷键设置页：集中展示 macOS 标准命令，并允许自定义 FloralMD 的格式、视图、窗口置顶、手动检查更新和系统级快速记录快捷键；支持冲突提示、清除、恢复默认和旧快速记录设置迁移。
- 快捷键设置现在支持搜索和隐藏固定的 macOS 标准命令；新增 `⌘⇧P` 命令面板、`⌃⌘F` 全屏命令和可配置的“缩至最小窗口”，快速记录窗口默认使用 550×400 的最小尺寸。

#### 变更
- 产品、模块、Bundle Identifier、Quick Look、偏好与日志目录、构建发布链及项目文档统一采用 FloralMD 身份；新的公开仓库与 Sparkle feed 使用独立的孤儿分支快照历史。

#### 修复
- 修复“自动为新草稿创建文件”和“启用快速记录”无法启用的问题；目录选择器现在会清晰显示在设置窗口前方，选择成功后保留开关状态，取消则保持关闭。

### English

#### Added
- All pinned document windows now use a fixed translucent background while
  keeping text, the caret, controls, images, and equations fully opaque. The
  background returns to opaque when pinning is disabled, in full screen, or
  when Reduce Transparency or Increase Contrast is enabled.
- Added a unified Shortcuts settings pane that lists fixed macOS-standard
  commands and lets users customize FloralMD formatting, view, window pinning,
  manual update-check, and system-wide Quick Capture shortcuts, with conflict
  feedback, clearing, default restoration, and migration of existing Quick
  Capture settings.
- Shortcut settings now support search and hiding fixed macOS-standard
  commands. Added a `⌘⇧P` command palette, explicit `⌃⌘F` full screen,
  a configurable minimum-window command, and 550×400 Quick Capture windows.

#### Changed
- Standardized the product, modules, bundle identifiers, Quick Look extension,
  preferences and log paths, build and release pipeline, and project
  documentation on the FloralMD identity. The new public repository and
  Sparkle feed use independent orphan snapshot histories.

#### Fixed
- Fixed Automatically Create a File for New Drafts and Enable Quick Capture
  failing to turn on. The folder picker now appears clearly in front of
  Settings, successful selection keeps the requested settings enabled, and
  cancellation leaves them off.

## [2026.7.0] — 2026-07-15

### 中文

#### 新增
- 现在可以在文件侧边栏中双击文件名直接重命名 Markdown 文件；扩展名会自动保留，并提供清晰的校验反馈。
- 现在可以为“快速记录”设置全局快捷键，从任意应用打开轻量的未命名笔记；文档窗口也可通过“窗口始终置顶”保持在其他应用之上。
- 文档保存现在可设为自动或仅手动，自动保存间隔支持 1 到 30 秒；非空未命名文档还可在指定文件夹中自动完成首次保存。

#### 变更
- 新建文档窗口现在默认收起两侧边栏，同时保留原有控件，仍可在当前窗口中展开任一侧边栏。
- 标题栏与侧边栏重命名现在共用协调且不会覆盖现有文件的处理流程，并支持同步已打开文档的 URL 以及仅变更大小写的重命名。
- “快速记录”现在以紧凑浮动窗口打开，不会改变普通窗口保存的尺寸；置顶窗口进入全屏时会暂时恢复普通层级，退出全屏后再恢复置顶。
- 此版本以 FloralMD 的 Bundle Identifier、feed 地址和 build 1 建立全新初始化的公开发布与 Sparkle 更新链。

#### 修复
- 自动保存现在会可靠启动、清除过期的编辑状态、在退出前保存所有已命名文档并显示保存状态；同时避免误报外部修改冲突，并保留真正尚未保存的本地内容。
- 原生文档标签页现在会正确显示并清除未保存标记；外部文件发生无冲突修改时，已打开文档也会安全刷新。

### English

#### Added
- Markdown files can now be renamed in place by double-clicking their name in
  the file sidebar, with extension preservation and clear validation feedback.
- Quick Capture can be assigned a global shortcut to open a low-friction
  untitled note from any app, and document windows can be kept above other apps
  with Window Always on Top.
- Document saving can be automatic or manual-only, with automatic intervals
  from 1 to 30 seconds and optional first-save of nonblank untitled documents
  into a chosen folder.

#### Changed
- New document windows now start with both sidebars collapsed, while keeping
  the existing controls available to expand either sidebar for that window.
- Titlebar and sidebar renaming now share coordinated, non-overwriting file
  handling, including open-document URL synchronization and case-only renames.
- Quick Capture opens as a compact floating window without changing the saved
  size of normal windows; pinned windows temporarily return to the normal level
  in full screen and restore afterward.
- This release establishes the newly initialized FloralMD public release and
  Sparkle update chain with its bundle identifier, feed URL, and build 1
  baseline.

#### Fixed
- Automatic saving now starts reliably, clears stale edited state, flushes
  named documents before quit, reports save status, and avoids false
  external-change conflicts while preserving genuinely unsaved local work.
- Native document tabs show and clear their unsaved marker correctly, and clean
  external file changes refresh open documents safely.

## [0.2.1] — 2026-07-14

### Added
- An Editor settings pane for typewriter scrolling, source presentation, and
  the semantic minimap, with matching controls in the View menu.
- Ordered lists automatically renumber after insertion, deletion, indentation,
  and dedentation.
- Block quotes support CommonMark lazy continuation lines more consistently.
- Nested reference definitions resolve in edit mode and exported HTML.
- Inactive table data rows display horizontal separators while preserving the
  shared column grid and independent wrapping in every cell.
- A bounded memory incident watchdog records diagnostic context only when
  process memory crosses conservative thresholds.

### Changed
- Editor preferences now stay synchronized across Settings, menu shortcuts,
  and every open document window.
- Western and Chinese body fonts can now be chosen independently while sharing
  one body size. Both follow macOS by default, with the concrete active fonts
  shown in Appearance settings; former Iowan Old Style defaults migrate to the
  system Western font automatically.
- Git gutter markers now distinguish additions, modifications, and deletions
  and refresh as the document changes.

### Fixed
- Pressing Return around list markers no longer duplicates an existing marker.
- Plain-text fenced code blocks no longer receive syntax highlighting.
- Git gutter markers remain visible across blank lines and active-block
  restyling, including adjacent deletions.
- The memory watchdog no longer inherits main-actor isolation, preventing a
  crash on its first background sample.

## [0.2.0] — 2026-07-13

### Added
- Finder Quick Look previews for Markdown files, rendered with FloralMD's
  existing read-mode HTML and styling.
- A collapsible document outline, a repository-aware Markdown file tree, and a
  read-only Git status panel.
- Git change markers in the editor gutter, recursive Git coloring in the file
  tree, nested-list indentation guides, and a semantic document minimap.
- English and Simplified Chinese interface localization across the app menus,
  editor chrome, sidebars, and Settings.

### Changed
- Forked from Edmund at commit `a32f7b3` and established the independent
  FloralMD product identity, bundle identifiers, build targets, documentation,
  and application icon.
- Synchronized Edmund upstream through `e45a753`, bringing the latest reference
  links, inline display math, raw HTML, code-span, list, and link-title support
  into FloralMD while preserving its independent application shell.
- Reworked inactive Markdown tables so every cell wraps independently while
  rows continue to share aligned column tracks and visible borders.
- Simplified the public documentation around FloralMD's current features and
  stable architecture.

### Fixed
- Ordered-list markers now enter rendered list geometry only after the
  following space, avoiding a distracting two-step horizontal jump.
- Manually wrapped and nested list continuations align with their owning list
  content without changing the stored Markdown whitespace.
- Minimap dragging no longer moves the application window.

## Upstream Edmund history

The entries below describe Edmund's upstream development history. They are
retained for provenance and must not be interpreted as FloralMD releases.

## [Edmund upstream unreleased synchronized through e45a753]

GFM pass: closing the gaps between Edmund and the GFM spec in both edit and read mode.

### Added
- Setext headings (`Title` underlined by `===`/`---`) render in edit mode
- Indented code blocks (4 spaces or a tab, after a blank line) render in edit mode
- HTML `<!-- comments -->`: dimmed in edit mode, hidden in read mode (previously showed as literal text in read mode)
- `<small>` added to the rendered HTML whitelist (both modes)
- `<img src alt width height>` renders the image in both modes, at its declared size (one dimension alone scales proportionally); remote/local image policy applies as for markdown images
- Autolinks ([GFM extension](https://github.github.com/gfm/#autolinks-extension-)): bare `www.…`, `http(s)://…`, and email addresses become links in both modes, with CMD+click to follow
- Inline styling (bold, code, links, ==marks==, …) now renders inside table cells in edit mode; column widths align on the *styled* text, not the raw source
- Inline styling inside headings keeps the heading's font size (`# **bold** and `code``), for ATX and setext headings
- Raw HTML renders in read mode per GFM ([§4.6](https://github.github.com/gfm/#html-blocks)/[§6.10](https://github.github.com/gfm/#raw-html)) with the tagfilter extension ([§6.11](https://github.github.com/gfm/#disallowed-raw-html-extension-)) plus hardening: `on*` event-handler attributes and `javascript:`/`vbscript:` URLs stripped, and a `script-src 'none'` CSP on the page (JS was already disabled)
- HTML blocks (all seven GFM §4.6 start conditions) parse as blocks in edit mode and show as colored source
- Full GFM §6.10 inline tag grammar in edit mode: hyphenated tag names, single-quoted/unquoted attribute values, `>` inside quoted values, and PI/declaration/CDATA tokens
- Multi-backtick code spans in edit mode (`` ``a`b`` ``) style with their real delimiter length
- Loose vs tight lists in read mode: tight lists drop the `<p>` wrapper inside items per GFM §5.3
- Link `title` attributes carry into read-mode/exported HTML

### Changed
- Read mode no longer escapes unknown HTML — GFM passthrough (with tagfilter + hardening) replaces the escape-by-default whitelist
- A `---` line directly under a paragraph is now a setext h2 underline per GFM, no longer a thematic break — put a blank line between the paragraph and `---` to keep the rule
- `==highlight==` now follows GFM-style flanking: content can't begin or end with whitespace (`== spaced ==` stays literal)
- Setext heading content spans the whole preceding paragraph run (`Foo\nbar\n---` is one h2), matching GFM Example 51
- Interior blank lines stay inside an indented code block (GFM Examples 82/87)

### Fixed
- Tables whose delimiter row cell count differs from the header are no longer parsed as tables in edit mode (GFM Example 203)
- Backslash-escaped pipes (`\|`) are cell content, not column separators (GFM Example 200)
- The ATX heading closing sequence (`# foo ###`) hides like other delimiters instead of showing in the heading (GFM 4.2)
- A newline inserted at a display-math block boundary no longer leaves a stray centered line (separator newlines now reset when adjacent blocks restyle)

## [0.1.4] - 2026-07-09

Various small fixes and improvement and new round of grind at the [delete caret drift](https://github.com/I7T5/Edmund/issues/156). I think it actually worked this time, but don't quote me on it. 

### Added
- `CMD+=`, `CMD+-`, and `CMD+0` to zoom in/out/reset. Also in View menu
- External images rendering in editor
- Block external images setting in Settings > Advanced 

### Changed
- Rename "Source Mode" to "Show Source in Editor" in app and button menu. Removed icon from button menu. 
- Opening an existing file closes the last opened Untitled window with no edit history
- Move Automatic updates to Settings > General
- Apply Settings > Appearance > Max content width to read mode 

### Fixed
- Images have extra bottom padding when editor is not in full screen
- Images do not resize with max content width if the user changes the setting when the app is open
- Tables overflow handled by horizontal scroll
- Callouts have an extra line at the bottom when they are the last element of a file
- Footnotes rendering in edit mode and linking between inline marker and content in read mode
- Math environments `\begin{}...\end{}` padding offset in edit mode
- Math environments `\begin{}...\end{}` rendering in read mode
- Delete caret drift, round 7 ([docs](docs/delete-drift-investigation.md)) [#156](https://github.com/I7T5/Edmund/issues/156)

---

## [0.1.3] — 2026-07-04

### Fixed
- Delete caret drift *with reproduction* [#156](https://github.com/I7T5/Edmund/issues/156)

---

## [0.1.2] — 2026-07-03

Polishing the editor and trying to have Fable 5 fix all the big bugs while I still have it with me. 

### Changed
- Redo now jumps to where changed text was instead of caret
- Removed old code for identity mapping, etc., using [ponytail](https://github.com/DietrichGebert/ponytail)-review

### Fixed
- Updater [#158](https://github.com/I7T5/Edmund/issues/158)
- Icon display for callouts with custom titles
- Undo/redo viewport glitches from TextKit 2
- Delete caret drift [#156](https://github.com/I7T5/Edmund/issues/156)

---

## [0.1.1] — 2026-06-29

### Added
- Thematic Break `---`/`***` in the Format menu
- Remember window size: new document windows reopen at the size of the last one.

### Changed
- Max content width is now an absolute physical width (cm / in) with a max-width cap and a cm/in unit toggle. 
- Typewriter Mode renamed to Typewriter Scroll

### Fixed
- Typewriter Scroll no longer jumps the viewport when you click to reposition the caret — it re-centers only while typing.

---

## [0.1.0] — 2026-06-27

First public release.

- **Live WYSIWYG preview** — Typora/Obsidian style
- **GFM support** — bold, italic, strikethrough, tables, task lists, fenced code with syntax highlighting, blockquotes, alerts
- **Extended syntax** — ==highlights==, [[WikiLinks]], `[^footnotes]`, Obsidian-flavored callouts and comments
- **Math** — inline (`$…$`) and display (`$$…$$`) rendering via SwiftMath
- **Native macOS UI** — AppKit editor, SwiftUI settings panel, full Dark Mode support
- **Keyboard-first** — configurable shortcuts, no required mouse interaction
- **Auto-update** — Sparkle 2.x with EdDSA-signed appcast; checks on launch
- **Open source** — Apache 2.0

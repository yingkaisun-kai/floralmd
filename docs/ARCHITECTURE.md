# FloralMD 架构概览

本文档介绍 FloralMD 的主要技术结构、核心约束和常用代码入口。

## 1. 项目定位

FloralMD 是一款原生 macOS Markdown 编辑器，强调直接打开任意位置的单个文件、行内实时渲染和本地优先。项目使用 Swift、AppKit、TextKit 2 与 Swift Package Manager，最低支持 macOS 14。

主要目标包括：

- 无需 Vault 或工作区即可打开 `.md` 文件；
- 在同一窗口中通过原生标签页处理多个文档；
- 编辑时提供行内实时渲染，阅读时提供完整 HTML 渲染；
- 保持 Markdown 文件内容可移植，不引入专有存储格式。

## 2. 构建与测试

```bash
swift build
swift test
./scripts/build-app.sh
```

普通本地构建生成 `build/FloralMD-Debug.app`：bundle ID、偏好、日志和可执行文件
均与正式版隔离，不声明 Markdown 文档类型，也不包含 Sparkle。只有调试 Quick Look
时才显式运行 `./scripts/build-app.sh --with-quick-look`，此时嵌入使用独立 ID 的
Debug Quick Look 扩展。`--variant production` 只供发布脚本与 Release CI 使用；
日常正式版必须从 GitHub Release DMG 安装。

Finder 会优先使用 `Contents/Resources/*.lproj/InfoPlist.strings` 中的本地化
名称，而不是主 `Info.plist`。构建脚本因此必须在复制共享本地化资源后覆盖 Debug
专用名称，并逐语言验证 `CFBundleName` 与 `CFBundleDisplayName`；只检查主 plist
不能证明 Debug 的显示身份已隔离。

Quick Look `.appex` 是独立 bundle，不能依赖宿主图标或 IconServices 的历史回退。
Production 与专项 Debug 扩展都在自己的 `Info.plist` 中以 `CFBundleIconFile`
声明 `AppIcon`，并在 `Contents/Resources` 内携带与宿主逐字节相同的
`AppIcon.icns`；构建时还会把扩展的营销版本与构建号同步到宿主，确保系统能识别
新的扩展资源。`scripts/build-app.sh` 会在签名后的 bundle 验证这些条件。

Swift Package 包含三个主要 Target：

- `FloralMDCore`：解析、编辑、渲染与文档模型；
- `floralmd`：基于 `NSDocument` 的应用外壳、窗口、菜单和设置；
- `FloralMDQuickLook`：Finder Quick Look 扩展。

## 3. 两项核心约束

### 3.1 文本存储始终等于原始 Markdown

编辑器的渲染只修改富文本属性，不插入或删除展示字符。Markdown 标记通过近乎零尺寸的字体与透明颜色隐藏，但底层字符串保持不变。因此：

- 展示位置与源码位置一一对应；
- 保存时无需从富文本反向还原 Markdown；
- 不使用会向文本中插入替代字符的 `NSTextAttachment`。

### 3.2 只使用 TextKit 2

编辑器通过 `NSTextLayoutManager` 使用 TextKit 2 的视口布局能力。代码不得访问 `NSTextView.layoutManager`，也不得写入 `NSTextBlock` 或 `NSTextTable` 属性，否则 AppKit 可能静默切回 TextKit 1，并破坏大文档性能和自定义绘制。

## 4. 编辑与渲染流程

```text
Markdown 源码
    ↓ BlockParser
逻辑块列表
    ↓ SyntaxHighlighter + styleBlock
富文本属性
    ↓ TextKit 2
编辑器画面
```

- `BlockParser` 将源码拆分为段落、标题、列表、引用、代码块、表格等逻辑块；
- `SyntaxHighlighter` 识别 CommonMark、GFM 与 FloralMD 支持的扩展语法；
- `styleBlock(_:cursorPosition:)` 为单个逻辑块生成展示属性；
- 光标所在块显示原始 Markdown 标记，其他块显示渲染结果；
- 编辑后只重新解析和渲染受影响的区域，大文档使用延迟样式与视口提升控制开销。
- `NSText.didChangeNotification` 早于 `rawSource` 与块范围同步；依赖行号或
  解析结果的界面（例如 Git gutter）必须监听
  `.editorDidSynchronizeText`，不能直接在系统文本通知中刷新。
- 外部文件修改同时由 `NSFilePresenter` 和 `ExternalFileMonitor` 检测：前者
  覆盖协调写入，后者用 vnode 事件覆盖命令行工具以及“写临时文件后原子替换”
  的编辑器，并在 inode 被替换后重新挂载。未编辑文档自动调用
  `EditorTextView.reloadContent`；若本地也有未保存修改，则按“冲突处理”设置
  保留、询问或载入磁盘版本。重载会保留仍然有效的选区并清空旧撤销历史；
  输入法存在 marked text 时必须延迟到组合提交后，不能直接替换 TextKit 存储。

## 5. TextKit 2 自定义绘制

`DecoratedTextLayoutFragment` 是 FloralMD 的主要绘制扩展点：

- `.blockDecoration` 绘制 Callout、引用竖线、表格边框、分隔线、代码背景和列表缩进引导线；
- `.fragmentOverlay` 在字符位置绘制数学公式、图片、列表符号和复选框；
- `.tableRowPresentation` 在非激活表格中按共享列网格独立绘制每个单元格，使所有列都能在自己的矩形内换行。
- 表格列宽与图片缩放宽度都在样式化时写入展示属性；窗口 resize 改变内容列宽后，
  `updateContentInset()` 必须重新样式化这些宽度敏感块。只修改
  `textContainerInset` 会让 TextKit 2 的表格行停留在不同布局世代，表现为某一行
  的整套边框与单元格一起横向错位。
- 文档以换行符结尾时，TextKit 2 会把最终空行吸收到前一个片段；若前一个片段是
  表格末行，其绘制原点会丢失正常首行缩进。`DecoratedTextLayoutFragment` 只对
  这个末行场景补偿单元格内边距，避免文字、竖线和底线整体左移。

这些展示属性均不改变原始 Markdown 字符串。

## 6. 阅读模式与导出

阅读模式使用独立的 `WKWebView`，由 `DocumentHTML` 与 `HTMLRenderer` 将同一份 Markdown 解析结果转换为带主题的 HTML。PDF 导出与打印复用同一条 HTML 渲染路径。

阅读环境默认禁用 JavaScript，并对原始 HTML、外部链接和远程图片执行限制。数学公式、图标和允许的本地资源会转换为内联资源。

## 7. 主要代码入口

| 范围 | 位置 |
| --- | --- |
| 编辑器核心 | `Sources/FloralMDCore/TextView/EditorTextView.swift` 及其扩展 |
| Markdown 解析 | `Sources/FloralMDCore/Parsing/` |
| 行内与块级渲染 | `Sources/FloralMDCore/Rendering/` |
| 编辑行为 | `Sources/FloralMDCore/Editing/` |
| 阅读与导出 | `Sources/FloralMDCore/Export/` |
| 应用、文档与窗口 | `Sources/floralmd/App/` |
| 设置 | `Sources/floralmd/Settings/` |
| 侧栏与缩略图 | `Sources/floralmd/Views/` |
| Quick Look | `Sources/FloralMDQuickLook/` |
| 测试 | `Tests/FloralMDTests/` |
| 构建与发布脚本 | `scripts/` |

## 8. 应用界面结构

- 左侧大纲读取当前文档标题结构；
- 右侧文件树从当前文件向上寻找最近的 Git 仓库，否则回退到当前目录；
- 文件树单击文件行仍负责打开文档；仅双击文件名文本进入原位重命名，编辑的
  是主文件名并保留原扩展名。Return 提交，Escape 或失焦取消。文件夹不进入
  此流程。标题栏与侧栏共用 `DocumentFileRenameRequest` 的验证规则：不允许空名、
  路径分隔符、`.`、`..`、扩展名变化或覆盖同目录文件；仅大小写变化通过同目录
  隐藏临时名完成并在失败时回滚。
- 已打开文件的重命名必须通过对应 `NSDocument` 的协调移动路径完成，不能在磁盘
  移动后另行拼接运行态。目标名先以不覆盖方式预留，成功后由同一文档更新
  `fileURL`、标签标题、autosave 目标与文件监控，再统一刷新 Git baseline、侧栏
  选中状态和最近文档；未打开文件使用 `NSFileCoordinator` 执行相同验证后的移动。
- Git 面板读取工作区状态，但不在应用内执行提交或推送；
- Git 仓库根目录探测在主线程同步执行，因此必须基于稳定的文件系统路径做有界
  向上遍历；不能依赖 bookmark 或 Save As 产生的 `URL` 在卷根处自行稳定。
- 语义缩略图展示标题、列表、代码、Git 改动、光标和视口位置；
- 原生 `NSDocument` 窗口标签负责多文档切换；
- 应用仍在运行但没有可见文档窗口时，Dock 再激活完全交给 AppKit 的标准
  document-based reopen 流程创建至多一个未命名文档；
  `applicationShouldHandleReopen` 不得在返回 `true` 的同时手动调用
  `newDocument`，否则一次用户意图会有两个创建所有者。启动时打开已有文件、
  Finder 打开文件和窗口恢复也必须先于默认未命名创建，不能附带空白窗口；
- 每个新建、重新打开或由系统恢复创建的文档窗口，其窗口会话初始都收起左右
  侧栏；这不是 `UserDefaults` 设置，也不在后续刷新中重复应用，用户展开后会在
  该窗口会话内保持展开。快速记录继续复用同一初始状态并保留其紧凑窗口策略。
- 文件侧栏是窗口最左侧的主栏，大纲是紧邻正文的次级面板；文件侧栏展开时，大纲
  与编辑区域整体右移，文件侧栏收起后两者回到窗口左缘。两个开关固定并排放在红
  绿灯右侧的 leading `NSTitlebarAccessoryViewController` 中，同一按钮负责展开和
  收起。两栏收起时都在内容布局中占用 `0` 宽度，不会留下全高 rail，也不会覆盖
  正文、滚动条或 minimap。
- 编辑模式、源码模式与阅读模式共享同一份文档状态。

## 9. 设置与本地数据

所有置顶窗口使用固定 88% 不透明度的背景。编辑器、阅读模式和侧栏只停止绘制各自的不透明底色，窗口本身不降低 `alphaValue`，因此文字、光标、控件、图片、数学公式和 TextKit 2 overlay 保持完全不透明。取消置顶或进入全屏会恢复不透明背景；系统启用“减少透明度”或“增强对比度”时也强制使用不透明背景，并监听辅助显示选项变化即时更新。

用户设置保存在 `UserDefaults`。设置窗口按通用、编辑器、快捷键、外观和高级分类；其中打字机滚动、源码显示和缩略图由 `AppSettings` 持久化，并通过 `EditorPreferenceCoordinator` 在设置、视图菜单、快捷键和所有已打开文档之间同步。

快捷键由 `ShortcutCatalog` 以稳定命令 ID 统一登记默认值、作用域和是否允许
自定义。`ShortcutManager` 从 `settings.shortcuts.overrides` 解析覆盖并实时重建
菜单；macOS 标准的新建、打开、保存、编辑和窗口命令只集中展示，不允许修改，
FloralMD 自有的格式、视图、置顶、手动检查更新和快速记录命令可以录制、清除或恢复
默认。设置页默认隐藏固定的 macOS 标准命令，可按需显示，并可按中英文名称、命令
ID、分类和当前快捷键搜索。普通菜单快捷键保存字符语义，系统级快速记录保存物理
key code；输入源变化时会重新计算后者的显示字符和应用内冲突。旧版
`settings.general.quickCaptureKeyCode` / `Modifiers` / `KeyLabel` 在
`settings.shortcuts.schemaVersion` 首次升级时迁入统一覆盖表。

`⌘⇧P` 打开的命令面板从同一命令目录读取名称、分类和当前快捷键，并通过
`CommandDispatcher` 将稳定 ID 映射到 AppKit responder chain；没有当前文档时，
文档级命令会置灰。第一版只暴露安全、可发现的文件、视图、窗口和格式命令，不包含
退出、隐藏、剪贴板和撤销等高频或容易误触的原生编辑动作。

快速记录是现有未命名文档流程的全局入口，而不是第二套便签存储：用户录制一个全局快捷键后，`GlobalHotKeyController` 通过系统离散热键 API 唤起 FloralMD，不需要监听全部键盘事件或申请辅助功能权限。热键使用独占注册做系统冲突的尽力检测，候选值先注册成功才替换旧值，因此冲突不会让已有快捷键失效；macOS 没有公开 API 枚举全部系统和其他应用快捷键，检测不能视为完备。每次触发会复用仍为空白的快速记录窗口，否则创建新的 `NSDocument`；快捷窗口在显示前即采用与普通文档硬下限一致的 550×400 窗口尺寸、禁止自动并入普通文档标签组并收起左右侧栏，不读取或覆盖普通文档的窗口尺寸偏好。普通文档也可执行“缩至最小窗口”，但该一次性动作不会覆盖下次新建普通窗口所用的已保存尺寸。窗口在当前 Space 以 `.floating` 层级显示，并继续使用下述未命名首次落盘流程。启用快速记录会同时启用未命名自动落盘，关闭后者也会关闭快速记录。快速记录启用期间，关闭最后一个窗口只让应用保持待命，`⌘Q` 才退出。置顶是窗口会话状态，不写入 Markdown、`UserDefaults` 或窗口恢复数据；普通文档可通过“窗口始终置顶”独立切换，原生标签组内的窗口层级保持一致，进入全屏时暂时降回普通层级，退出后恢复。全屏命令显式接入菜单和固定的 macOS 标准快捷键 `⌃⌘F`，不依赖 AppKit 自动插入菜单项。

文档保存可选择自动或仅手动模式；自动模式默认每 2 秒保存一次，也可选择 1、5、10 或 30 秒，手动模式保留 `⌘S` 与关闭确认。未命名文档的首次自动落盘是另一项默认关闭的设置：用户选择目标文件夹后，`Document` 只从 `.editorDidSynchronizeText` 接收已同步的非空白正文，确认没有 marked text，并按同一保存间隔 debounce；到期后以可读时间戳命名，用 `O_EXCL` 原子占位避免覆盖，再通过标准 `NSDocument` `.saveAsOperation` 获得首个 `fileURL`。目标目录以 security-scoped bookmark 数据持久化并由单一访问边界解析，为未来 App Sandbox 保留迁移路径；失败会保留内存正文并停止，只有再次编辑或设置变化才重试。首次落盘成功后的周期保存仍完全由前一项设置决定。

`Document.autosavesInPlace` 只声明文档支持原地自动保存；`AppSettings.applyDocumentSaving()` 还必须把 `NSDocumentController.autosavingDelay` 设为正数才能真正启动周期性保存，值为 `0` 表示禁用。窗口副标题以 `NSDocument` 的脏状态与保存回调为准，显示未保存、正在保存、已保存或保存失败；保存成功后还会核对磁盘正文与当前 `rawSource`，只有完全一致才修复残留脏状态。自动模式关闭有待保存变化的文件时会先完成一次不可取消的原地保存，等 change-token 落定后再次核对磁盘，再进入系统关闭流程。周期自动保存虽然已经更新原文件，AppKit 仍可能保留“未显式保存”的内部关闭基线；因此 `canClose` 只有在再次确认磁盘与当前 `rawSource` 完全一致时才直接完成公开的 `shouldClose` 回调。`⌘Q` 则由 `DocumentController.reviewUnsavedDocuments` 在系统弹窗之前顺序刷新全部已命名文档。AppKit 会在调用该方法前缓存“需要审查”的判断，所以全部保存成功并再次确认没有脏文稿后，控制器直接完成其公开的 `didReviewAll` 回调；若再调用 `super`，系统会沿用旧判断并错误显示 Save/Revert 弹窗。

底层 vnode 文件监控无法识别写入进程，因此 FloralMD 在自身保存期间暂停并取消监控通知，完成后重新绑定路径；`NSFilePresenter` 还可能在保存完成后延迟送达通知，所以文档会保留最近一次自身写入快照，并先与磁盘内容核对来源。若落盘内容不等于该次保存快照，则立即补做外部修改检查。这样持续输入时不会把上一拍自动保存误报为外部冲突，真正不同的外部写入仍保留冲突策略。手动模式、未启用首次落盘的未命名文档和保存失败仍使用标准保存确认。

主题与字体仍由 `EditorTheme` 作为独立领域模型管理。正文字体拆分为共用字号的西文基础字体和中文级联字体：两者默认都跟随 macOS，且可分别选择；设置窗口在系统模式下仍显示当前实际字体（SF Pro 与系统解析出的中文字体）。阅读模式用相同顺序生成 CSS 字体栈。旧版默认产生的 `Iowan Old Style` 与 `IowanOldStyle-Roman` 在加载时迁移到系统西文字体，其他用户选择保持不变。应用默认在本地处理文件，不要求账户或云端服务。

## 10. 公开快照与更新 feed

公开 `main` 按产品版本保存可独立测试与构建的源码快照，正式版本 tag 指向对应
快照提交。维护者的导出、快照准备和远端发布控制工具属于内部开发基础设施，不是
公开产品源码或构建输入，因此不包含在本仓库的公开快照中。

Sparkle 的稳定 feed URL 与 EdDSA 公钥内置在 `Info.plist`；私钥只存在
维护者钥匙串和 GitHub Actions 的
`FLORALMD_SPARKLE_ED_PRIVATE_KEY` secret 中。公开仓库的孤儿 `feed`
分支只保存 `appcast.xml`；tag 触发的 release workflow 构建 DMG、生成
GitHub Release、用私钥签名 DMG，然后把新条目推入 `feed`。根目录不保存
运行中的 appcast，避免 CI 生成的 feed 提交污染源码快照历史。

`CHANGELOG.md` 是 GitHub Release 与 Sparkle 更新说明的共同来源。CalVer 版本
保持 `## [YYYY.MM.PATCH] — YYYY-MM-DD` 边界，版本内固定先写完整的
`### 中文` 区块及其 `#### 新增` / `#### 变更` / `#### 修复` 等类别，再写完整的
`### English` 区块及对应 Keep a Changelog 类别；不使用 `中文：` / `English:`
行内标签，也不依赖行内粗体区分语言。`.github/workflows/release.yml` 与
`scripts/release.sh` 都通过 `scripts/extract-release-notes.py` 生成合法 Markdown，
`scripts/changelog-to-html.py` 复用同一版本边界并把两级区块标题转换为 Sparkle
HTML，因此四级类别标题不会结束当前版本，只有下一个 `## […]` 版本标题会结束。
旧交替格式把缩进的中文行折叠为前一个英文列表项的 continuation；其中
`**中文：**现在…` 的闭合星号位于标点与汉字之间，不满足 CommonMark 的
right-flanking 分隔符条件，GitHub 因而原样显示星号。新结构不再依赖这类行内强调。

普通 CI 与 tag 发布 workflow 都固定使用 `macos-26` runner，并在日志中记录
实际 Xcode 与 Swift 版本。`latest-stable` 只在这个明确的 runner 世代内选择；
SwiftPM cache 使用 `spm-v3-macos26` 代际，不能复用旧 `macos-14` / Xcode 16
产生的构建缓存。runner 和编译器版本不改变 `Package.swift` 声明的 macOS 14
最低部署目标。

标准“检查更新…”菜单、`SPUStandardUpdaterController`、feed 和公钥都只属于
Production；Debug 不导入、链接或嵌入 Sparkle，也不显示该菜单。
`scripts/build-app.sh` 同时检查两种产物：Production 必须含正确 feed、非空公钥、
Sparkle framework 和手动菜单；Debug 必须全部不含。自动检查开关使用
Sparkle 的 `SUAutomaticallyChecksForUpdates` UserDefaults key。拉取 feed 后，Sparkle 先按
`sparkle:version` 比较单调递增的 `CFBundleVersion`，再用内置公钥校验下载件签名。

FloralMD 从 `2026.7.0` 起使用 `YYYY.MM.PATCH` 日历版本：同月发布递增 PATCH，
跨月的首次发布从 PATCH 0 开始，没有发布的月份可以跳过。Git tag、GitHub
Release 标题和 DMG 名称分别使用 `v2026.7.0`、`FloralMD 2026.7.0` 和
`FloralMD-2026.7.0.dmg` 的对应形式。`CFBundleVersion` 是另一条独立整数序列，
在同一条已安装客户端可升级的发布链中必须严格递增；appcast 分别把营销版本写入
`sparkle:shortVersionString`，把构建号写入 `sparkle:version`。2026-07-15 的一次性
公开体系重建明确放弃旧 Sparkle 链，并要求用户手动重装，因此新链以
`2026.7.0 / build 1` 开始；从该基线起不得再次重置，下一版至少为 build 2。

## 11. 许可与反馈

FloralMD 使用 Apache License 2.0，来源与上游署名见根目录的 `NOTICE` 和 `README.md`。

如果遇到问题，欢迎附上 macOS 版本、FloralMD 版本、复现步骤和必要截图，方便定位原因。

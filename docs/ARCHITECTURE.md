<!-- Modified from Edmund by Yingkai Sun for FloralMD. -->
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
`AppIcon.icns` 还必须保留 alpha 通道：若圆角图标以不透明 RGB 画布封装，Finder
和 DMG 会把圆角外的画布显示成白色方块。构建脚本会在复制资源前用 `sips` 拒绝
这种产物，`Resources/AppIcon.png` 与 `docs/assets/AppIcon/` 中的派生 PNG 也统一
保留透明角。

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
- 编辑器使用与 `NSTextView` 内建撤销相互独立的源码快照栈，因此
  `NSDocument` change count 必须按自定义撤销组同步：每个新组只发送一次
  `.changeDone`，Undo/Redo 分别发送 `.changeUndone` / `.changeRedone`，格式化、
  缩进和输入法恢复也必须发送 `.editorDidSynchronizeText`。保存 token 会切断当前
  输入合并组，否则保存后继续输入可能被并入保存前的撤销组而保持错误的干净状态。
- 外部文件修改同时由 `NSFilePresenter` 和 `ExternalFileMonitor` 检测：前者
  覆盖协调写入，后者用 vnode 事件覆盖命令行工具以及“写临时文件后原子替换”
  的编辑器，并在 inode 被替换后重新挂载。未编辑文档自动调用
  `EditorTextView.reloadContent`；若本地也有未保存修改，则按“冲突处理”设置
  保留、询问或载入磁盘版本。重载会保留仍然有效的选区并清空旧撤销历史；
  输入法存在 marked text 时必须延迟到组合提交后，不能直接替换 TextKit 存储。
  `DispatchSource.resume()` 返回不代表 vnode 监听已经注册；需要紧接着写入的测试
  必须等待 registration handler 确认就绪，不能用 sleep 或延长超时猜测注册时序。

## 5. TextKit 2 自定义绘制

`DecoratedTextLayoutFragment` 是 FloralMD 的主要绘制扩展点：

- 原生插入点保持透明，前景短光标由显式 `NSTextInsertionIndicator` 绘制。输入法
  marked text 尚未提交时，`rawSource` 有意不包含组合串；短光标必须用 TextKit
  存储中的 marked range 与其内部 selection 计算位置，不能把位置截断到
  `rawSource.count`，也不能为了刷新光标而同步或重写存储；
- 文末光标遇到换行后的空段落时，TextKit 2 可能还没有该行 fragment。
  此时只从前一行合成一次终端空行几何；行进距离必须额外包含用户的
  `lineSpacing + paragraphSpacingBefore`，否则短光标会在首字符形成真实 fragment
  时向下跳。打字机模式同时扩展文本视图底部可滚动空间，让 Return 后立即居中；
  不得往 Markdown 存储插入占位字符。关闭打字机模式时必须清除这段临时最小高度；
- `.blockDecoration` 绘制 Callout、引用竖线、表格边框、分隔线、代码背景和列表缩进引导线；
- `.fragmentOverlay` 在字符位置绘制数学公式、图片、列表符号和复选框；
- 行内公式 overlay 的 ascent 写入 `minimumLineHeight`，descent 写入段后间距；
  不得把整张公式图片高度都塞进 `minimumLineHeight`，否则基线会被压到行框底部，
  积分号或分式的下沉部分会与下一段重叠。列表项中的独占 `$$…$$` 保留列表段落
  缩进，只在标记所在行预留块公式高度；`$$…$$` 与正文同处一行时仍按行内流布局。
- `.tableRowPresentation` 在非激活表格中按共享列网格独立绘制每个单元格，使所有列都能在自己的矩形内换行。
- 短表格至少占正文列约三分之二，长表格最多占满正文列；编辑与阅读模式都使用无外框、无竖线的开放式表格，只在表头下方和相邻数据行之间绘制横向分隔线。单元格多行文本继承用户设置的正文行高。
- 表格列宽与图片缩放宽度都在样式化时写入展示属性；窗口 resize 改变内容列宽后，
  `updateContentInset()` 必须重新样式化这些宽度敏感块。只修改
  `textContainerInset` 会让 TextKit 2 的表格行停留在不同布局世代，表现为某一行
  的整套边框与单元格一起横向错位。
- TextKit 2 的系统插入点会包含段落 `lineSpacing`，因此高行距会把光标拉到整行框
  高度，而且实际的 TextKit 2 路径不会调用 `NSTextView.drawInsertionPoint`。编辑器将
  系统插入点设为透明，使用前景 `NSTextInsertionIndicator`，显式管理 first responder、
  选择范围、字体高度与闪烁计时；不能依赖该视图的 `.automatic` 模式自行激活。文末
  连续换行产生的终止空段落没有 TextKit 2 fragment，此时从前一空行推导位置并按有效
  字体缩短，不能退回整行框。
- 文档以换行符结尾时，TextKit 2 会把最终空行吸收到前一个片段；若前一个片段是
  表格末行，其绘制原点会丢失正常首行缩进。`DecoratedTextLayoutFragment` 只对
  这个末行场景补偿单元格内边距，避免文字、竖线和底线整体左移。

这些展示属性均不改变原始 Markdown 字符串。

## 6. 阅读模式与导出

阅读模式使用独立的 `WKWebView`，由 `DocumentHTML` 与 `HTMLRenderer` 将同一份 Markdown 解析结果转换为带主题的 HTML。PDF 导出与打印复用同一条 HTML 渲染路径。

阅读环境默认禁用 JavaScript，并对原始 HTML、外部链接和远程图片执行限制。数学公式、图标和允许的本地资源会转换为内联资源。只有忽略空白后独占段落的
`$$…$$` 才输出块公式；正文中的 `$$…$$` 使用 display 模式渲染但保持行内流，
代码 span 或 fenced code 中的美元符号始终按字面量保留。

Finder Quick Look 继续返回自包含的数据型 HTML，并在每次打开预览时从扩展进程的
`effectiveAppearance` 解析浅色或深色调色板。Quick Look 的数据型 HTML 宿主不会
可靠响应 `prefers-color-scheme`，且 reply 生成后不可变；因此系统外观切换后需要
关闭并重新打开预览才会重新取值，不为实时切换引入带额外网络权限的 `WKWebView`。

编辑与阅读模式按源码行保持视口：`HTMLRenderer` 给每个顶层块添加
`floralmd-l<起始行>` 锚点，`ReadModeAnchors` 暴露同一组行范围；WebView 通过只
插入数字的宿主静态 JavaScript 读取或设置“锚点行 + 块内比例”。这不放开页面脚本，
`allowsContentJavaScript = false` 与 CSP 继续约束文档内容。编辑侧只使用 TextKit 2
把 UTF-16 源码位置与行号互换。两个方向都先在隐藏表面完成定位，再一次性交换视图：
Edit→Read 等 HTML 和滚动恢复完成，Read→Edit 等异步位置读取及 TextKit 2 滚动
完成，因此不会先显示旧位置再跳动。进入 Read 的锚点必须在 `viewMode` setter
重组离屏块之前取得；远距离返回 Edit 时还必须先同步样式化并布局目标以上的块，
否则离屏高度估算在后台变成真实高度后会继续推动视口。

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

- 文档大纲读取当前文档标题结构；
- 文件侧栏从当前文件向上寻找最近的 Git 仓库，否则回退到当前目录；
- 文件树单击文件行仍负责打开文档；仅双击文件名文本进入原位重命名，编辑的
  是主文件名并保留原扩展名。Return 提交，Escape 或失焦取消。文件夹不进入
  此流程。标题栏与侧栏共用 `DocumentFileRenameRequest` 的验证规则：不允许空名、
  路径分隔符、`.`、`..`、扩展名变化或覆盖同目录文件；仅大小写变化通过同目录
  隐藏临时名完成并在失败时回滚。
- 已打开文件的重命名必须通过对应 `NSDocument` 的协调移动路径完成，不能在磁盘
  移动后另行拼接运行态。目标名先以不覆盖方式预留，成功后由同一文档更新
  `fileURL`、标签标题、autosave 目标与文件监控，再统一刷新 Git baseline、侧栏
  选中状态和最近文档；未打开文件使用 `NSFileCoordinator` 执行相同验证后的移动。
- 文件树右键菜单保持文档导航范围：Markdown 文件提供打开、重命名、在 Finder 中
  显示、复制路径和移到废纸篓，文件夹只提供 Finder 显示与复制路径，不承担递归删除
  或新建目录。删除必须使用 `NSWorkspace.recycle` 的可恢复废纸篓语义；已打开文件先
  经过 `NSDocument.canClose` 的未保存审查，回收期间暂停路径监控，只有系统回收成功
  才关闭标签并刷新全部侧栏与 Git 状态，失败时保留标签和内存正文。
- Git 面板读取工作区状态，但不在应用内执行提交或推送；
- Git 仓库根目录探测在主线程同步执行，因此必须基于稳定的文件系统路径做有界
  向上遍历；不能依赖 bookmark 或 Save As 产生的 `URL` 在卷根处自行稳定。
- 语义缩略图展示标题、列表、代码、Git 改动、光标和视口位置。其纵轴统一使用
  源码 UTF-16 位置与按当前正文列宽估算的语义换行行：短文档保持自然行距并只占
  顶部所需高度，语义行总高度超过可用区域后才整体压缩。Git 标记、光标和
  TextKit 2 `viewportRange` 都转换到同一坐标；点击或拖动再反向得到源码位置，
  只布局目标片段并有限次收敛正文落点，不按 `document.bounds.height` 比例滚动，
  也不枚举或信任全部离屏 fragment 的估算 y 坐标；
- 原生 `NSDocument` 窗口标签负责多文档切换；
- 原生标签栏出现或消失时，AppKit 可能只改变 `contentView` 高度而不发送
  `NSWindow.didResize`。正文表面中以 frame 定位的顶部悬浮控件必须使用顶部锚定的
  autoresizing 或约束；否则新文件并入标签组后会保留旧 Y 坐标并被标签栏裁切。
- 应用仍在运行但没有可见文档窗口时，Dock 再激活完全交给 AppKit 的标准
  document-based reopen 流程创建至多一个未命名文档；
  `applicationShouldHandleReopen` 不得在返回 `true` 的同时手动调用
  `newDocument`，否则一次用户意图会有两个创建所有者。启动时打开已有文件、
  Finder 打开文件和窗口恢复也必须先于默认未命名创建，不能附带空白窗口；
- 每个新建、重新打开或由系统恢复创建的文档窗口，其窗口会话初始都收起左右
  侧栏；这不是 `UserDefaults` 设置，也不在后续刷新中重复应用，用户展开后会在
  该窗口会话内保持展开。快速记录继续复用同一初始状态并保留其紧凑窗口策略。
- 文件侧栏是窗口最左侧的窗口级主栏，其开关与置顶开关固定放在红绿灯右侧的
  leading `NSTitlebarAccessoryViewController` 中。大纲是紧邻正文的文档级次级
  面板：收起时入口固定悬浮在编辑表面左上角的空白边距中，不随正文滚动；展开时
  面板推动编辑区域并在自身标题区提供收起按钮，不覆盖正文。文件侧栏展开时，大纲
  与编辑区域整体右移，文件侧栏收起后两者回到窗口左缘。两栏收起时都在内容布局中
  占用 `0` 宽度，不会留下全高 rail，也不会覆盖正文、滚动条或 minimap。
- 文档窗口使用透明 unified 标题栏，并在内容表面顶端绘制一条可控的细分隔线，让
  标题栏与编辑表面保持连续但仍可辨认；窗口底色必须随有效外观变化重新解析，否则
  启动阶段先创建的窗口会在深色模式下保留浅色标题栏。两侧栏使用稳定的冷中性
  实色层级，避免展开动画逐帧重算全高毛玻璃；置顶半透明仍由下述统一背景策略控制。
- 编辑模式、源码模式与阅读模式共享同一份文档状态。

## 9. 设置与本地数据

所有置顶窗口使用固定 88% 不透明度的背景。编辑器、阅读模式和侧栏只停止绘制各自的不透明底色，窗口本身不降低 `alphaValue`，因此文字、光标、控件、图片、数学公式和 TextKit 2 overlay 保持完全不透明。取消置顶或进入全屏会恢复不透明背景；系统启用“减少透明度”或“增强对比度”时也强制使用不透明背景，并监听辅助显示选项变化即时更新。

用户设置保存在 `UserDefaults`。设置窗口按通用、编辑器、快捷键、外观和高级分类；其中打字机滚动、源码显示和缩略图由 `AppSettings` 持久化，并通过 `EditorPreferenceCoordinator` 在设置、视图菜单、快捷键和所有已打开文档之间同步。

设置窗口使用 AppKit `NSSplitViewController` 保持固定左侧分类导航，右侧为缓存的
`NSHostingController`；五个 SwiftUI pane 继续拥有各自的 `@AppStorage`、sheet、
字体面板和即时副作用，只把内容组织为可滚动的卡片分组。切换分类不会重建 pane，
窗口缩放也不再由各 pane 的固有高度驱动。

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

快速记录是现有未命名文档流程的全局入口，而不是第二套便签存储：用户录制一个全局快捷键后，`GlobalHotKeyController` 通过系统离散热键 API 唤起 FloralMD，不需要监听全部键盘事件或申请辅助功能权限。热键使用独占注册做系统冲突的尽力检测，候选值先注册成功才替换旧值，因此冲突不会让已有快捷键失效；macOS 没有公开 API 枚举全部系统和其他应用快捷键，检测不能视为完备。每次触发会复用仍为空白的快速记录窗口，否则创建新的 `NSDocument`；快捷窗口在显示前即采用与普通文档硬下限一致的 550×400 窗口尺寸、禁止自动并入普通文档标签组并收起左右侧栏，不读取或覆盖普通文档的窗口尺寸偏好。普通文档也可执行“缩至最小窗口”，但该一次性动作不会覆盖下次新建普通窗口所用的已保存尺寸。快速记录默认使用“仅当前 Space”置顶；若用户已将可复用窗口切为“所有 Space”，再次唤起时保留该模式，而已取消置顶的窗口会恢复为“仅当前 Space”。窗口继续使用下述未命名首次落盘流程。启用快速记录会同时启用未命名自动落盘，关闭后者也会关闭快速记录。快速记录启用期间，关闭最后一个窗口只让应用保持待命，`⌘Q` 才退出。

置顶是窗口会话状态，不写入 Markdown、`UserDefaults` 或窗口恢复数据。每个原生标签组共享“不置顶”“仅当前 Space”“所有 Space”三态，标题栏左侧用 `pin.slash`、`pin.fill`、`globe` 常驻显示当前模式并提供三态菜单。前两态保留普通文档窗口的 `.primary + .fullScreenPrimary` 角色，仅通过 `.floating` 区分是否压过同一 Space 内的普通窗口。普通 titled `NSDocument` 窗口即使设置 `.canJoinAllSpaces + .fullScreenAuxiliary + .canJoinAllApplications`，也不能稳定进入另一个 App 的原生全屏 Space；“所有 Space”因此由 `AllSpacesPinnedPanelController` 把每个标签文档已有的编辑器内容视图、工具栏和 FloralMD 自建的标题栏 accessory 临时移入对应的 titled `.nonactivatingPanel`，这些面板按原顺序组成辅助标签组，只使用 `.canJoinAllSpaces + .fullScreenAuxiliary` 与 `.floating`。存储、撤销、选区和 IME 状态没有副本，退出该模式后原样移回普通文档窗口。面板登记为对应 `NSDocument` 的 window controller；每个原 `DocumentWindow` 只保留空占位视图，并临时设为 `alphaValue=0`、忽略鼠标，但不 `orderOut`。这个透明度只作用于没有正文的宿主，不会淡化文字或 overlay；保留宿主是必要的，因为 `orderOut` 最后一个文档窗口会触发应用退出，也会让 AppKit 在过渡期拆散原生 tab group。切回普通模式后，控制器保留未登记到 `NSDocument`、没有正文和工具栏的隐藏 Panel 外壳，后续切换直接复用以避开窗口分配；普通标签操作不在交互关键路径销毁这些休眠外壳，文档关闭或下次进入所有 Space 时才丢弃与当前标签成员不匹配的缓存。从文件侧栏打开新文档始终使用 `display: false`，完整消费 `pendingContent` 并加入目标标签组后才显示；“不置顶”和“仅当前 Space”只把模式应用到新窗口自身，不运行组级刷新。所有 Space 模式只为新文档增量创建或复用一个辅助 Panel，普通宿主从入组到 Panel 接管始终保持透明；已有 Panel 和正文视图不会拆卸，辅助标签的接入和激活推迟到下一轮主线程，但不强制同步绘制。模式切换和其余原生标签增删前使用面板创建时冻结的组成员统一恢复普通宿主，不能在 AppKit 过渡期重新查询组；辅助标签组内的标签切换则直接切换各文档自己的面板，模式图标和正文同步更新。FloralMD 自身请求全屏时会先恢复整个普通 `DocumentWindow` 标签组及其 `.primary + .fullScreenPrimary` 角色；退出或进入失败后若模式仍为“所有 Space”，再重建辅助标签组。全屏命令显式接入菜单和固定的 macOS 标准快捷键 `⌃⌘F`，不依赖 AppKit 自动插入菜单项。

设置页中依赖目录授权的开关不能在 `@AppStorage.onChange` 内同步调用
`NSOpenPanel.runModal()`：这会在 SwiftUI 控件事务尚未完成时进入新的模态循环，
面板可能落在设置窗口后方。开关先保留原状态，再在下一轮主循环把面板作为设置窗口
的 sheet 前置显示；只有 bookmark 保存成功后才一次性提交开关状态，取消则保持原值。

文档保存可选择自动或仅手动模式；自动模式默认每 2 秒保存一次，也可选择 1、5、10 或 30 秒，手动模式保留 `⌘S` 与关闭确认。未命名文档的首次自动落盘是另一项默认关闭的设置：用户选择目标文件夹后，`Document` 只从 `.editorDidSynchronizeText` 接收已同步的非空白正文，确认没有 marked text，并按同一保存间隔 debounce；到期后以可读时间戳命名，用 `O_EXCL` 原子占位避免覆盖，再通过标准 `NSDocument` `.saveAsOperation` 获得首个 `fileURL`。目标目录以 security-scoped bookmark 数据持久化并由单一访问边界解析，为未来 App Sandbox 保留迁移路径；失败会保留内存正文并停止，只有再次编辑或设置变化才重试。首次落盘成功后的周期保存仍完全由前一项设置决定。自动落盘、Quick Capture 复用、窗口脏状态与关闭审查共享 `UntitledDocumentContentPolicy`：仅当 `fileURL == nil`、没有 marked text 且正文 trim 空格与换行后为空时，文档才是可直接丢弃的空白未命名稿；已有文件即使被清空也始终保留普通文件语义。关闭窗口或 `⌘Q` 开始时先提交仍在进行的 marked text，再同步这一状态；清空会取消尚未触发的首次落盘，Undo 恢复非空正文则重新标脏并重新安排 debounce。

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

SwiftMath 的原生 SwiftPM CLI 构建只生成从 `Bundle.main.bundleURL`（应用包根目录）
查找资源的访问器，而标准 macOS 应用把 `SwiftMath_SwiftMath.bundle` 封装在
`Contents/Resources`。Production 因此通过 `swift build --build-system xcode`
构建；Xcode 的 SwiftPM 集成会生成应用感知的候选路径，优先检查
`Bundle.main.resourceURL`，再回退到 framework 和命令行位置。v2026.7.3 与
v2026.7.4 曾尝试在构建后修改 SwiftPM 的派生源码，但后续构建重新生成了访问器，
最终二进制仍只包含 `bundleURL`，导致首次渲染公式时触发 `NSBundle.module` 的
断言退出。打包门禁会检查最终 Mach-O 确实包含 `resourceURL` 选择器，并确认资源包
实际位于 `Contents/Resources`；不能只检查派生源码或目录中是否存在 `.bundle`。

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

FloralMD 使用 Apache License 2.0。根目录 `LICENSE` 保持许可证标准文本；项目、
Edmund 与 Swift Markdown 的署名及来源说明由 `NOTICE` 承担。能够从 Edmund
对应文件确认继承且内容发生变化的文本文件，必须携带一行
`Modified from Edmund by Yingkai Sun for FloralMD.`；纯重命名且内容相同的文件与
首次由 FloralMD 创建的文件不需要该声明。具体来源映射和发布前完整性检查属于内部
维护资料，不进入公开源码快照或发行包。

`scripts/build-app.sh` 把根 `LICENSE`、`NOTICE`、Lucide 许可及当前 SwiftPM
解析版本对应的 Swift Markdown、Swift CMark、SwiftMath 许可证复制到 app bundle；
Production 还复制 Sparkle 许可证。构建后的 sealed bundle 会逐项检查这些资源，
因此 DMG 不再依赖仓库网页或 Git 历史来提供第三方许可文本。

如果遇到问题，欢迎附上 macOS 版本、FloralMD 版本、复现步骤和必要截图，方便定位原因。

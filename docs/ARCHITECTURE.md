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

- `BlockParser` 将源码拆分为段落、标题、列表、引用、代码块、表格，以及文档首部
  YAML front matter 和行首 `%%` 多块注释等逻辑块；
- `SyntaxHighlighter` 识别 CommonMark、GFM 与 FloralMD 支持的扩展语法。
  `MarkdownFeatures` 是 Edit 与 Read 共用的独立能力集合；关闭某项后对应源码按
  字面量保留。GitHub 的 `NOTE` / `TIP` / `IMPORTANT` / `WARNING` / `CAUTION`
  alerts 与 Obsidian 专属 callout 类型分别开关，可折叠 `[-+]` 也单独控制；
- 围栏代码块通过 `CodeHighlighter` 的可插拔后端产生相对源码的 UTF-16 token，
  编辑与阅读模式共用 CotEditor 对齐的九类 scope 和同一调色板。默认
  `BuiltinSyntaxBackend` 从包内 `Resources/Syntaxes/*.json` 加载语言定义；
  `~/Library/Application Support/FloralMD/Syntaxes` 中同名 JSON 可覆盖内置定义，
  但别名不能覆盖另一语言的 canonical id。用户文件按文件名确定性加载，超过
  512 KiB、非普通文件、不可读或 schema 非法时均忽略并记录在
  `SyntaxDefinitionStore.loadIssues`，不影响其余定义；无语言围栏默认纯文本，
  未知但显式标注的语言保留通用 C-family 回退。非活动围栏保留等长、等行高的
  原始字符但清除其墨迹，并由 TextKit 2 fragment 在代码块左上直接绘制克制的
  语言标签；阅读 HTML 在代码块顶部绘制同一标签。两种模式都复用语法定义的展示名，
  无语言及 plain-text aliases 不绘制。编辑模式的 fenced code block 还以逐段平铺的
  `.blockDecoration` 绘制不改变行高、换行或选区几何的浅/深色背景和 8pt 圆角边界；
  语言标签与复制按钮复用 Read mode 的块级锚点（左上 12/9pt、右上 8/8pt），由事件
  穿透的前景视图绘制，避免紧凑开围栏 fragment 被后续代码行背景覆盖；它们不依赖
  首行文字的 typographic bounds，因此用户行距变化不会造成控件漂移；鼠标悬停
  只扫描 TextKit 2 已布局的 viewport fragment，并由事件透传的前景子视图显示复制
  控件。复制 payload 来自 `.codeBlockPresentation` 保存的原始 content range，不含
  fence 或语言名；点击只写剪贴板和控件反馈，不重组 storage、不移动选区或抢 first
  responder。活动代码块若开围栏 info string 占用右上区域，控件移到块内首个不重叠的
  已布局行，raw Markdown 继续优先可编辑；
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
- 光标遇到由换行界定的空段落时（包括文档中间与文末），TextKit 2 可能还没有
  该段自己的 fragment，而把边界位置吸收到上一段 fragment。此时从前一行合成
  空行几何；行进距离必须额外包含用户的
  `lineSpacing + paragraphSpacingBefore`，否则短光标会在首字符形成真实 fragment
  时向下跳。合成空行的自身高度必须匹配 AppKit 的实际字体行框，不能把 spacing
  塞进高度或向上取整，否则连续空行会累积偏移。显式插入点必须优先使用合成几何；
  输入法 marked text 仍优先使用其真实 TextKit 2 几何。打字机模式同时
  扩展文本视图底部可滚动空间，让 Return 后立即居中；
  文本编辑完成后必须在 `rawSource` 同步与打字机回正之后同步刷新显式插入点，
  不能只依赖 selection change 安排的下一轮刷新，否则视口已到新空行时短光标仍会
  短暂画在旧行；
  不得往 Markdown 存储插入占位字符。关闭打字机模式时必须清除这段临时最小高度；
- `.blockDecoration` 绘制 Callout、引用竖线、表格边框、分隔线、代码背景和列表缩进引导线；
- `.fragmentOverlay` 在字符位置绘制数学公式、图片、列表符号和复选框；
- 本地图片可由 `NSCache` 逐出并从磁盘重读；已成功下载的远程图片则在应用
  进程内强引用缓存，因为 `NSCache` 可自行逐出条目，不能保证后续重组不会
  重新发起网络请求；
- 可加载的图片 overlay 标记为可缩放角色；鼠标悬停边框与右下角把手由
  `EditorTextView` 的透明、事件穿透子视图绘制，保证位于 TextKit fragment overlay
  之上。拖动开始时该视图同时接管图片预览，原 fragment 图片只退出绘制一次；之后
  每个鼠标事件只更新前景视图 frame，避免 TextKit 合并缩小时完全落在旧绘制表面内的
  刷新。图片通常向上伸出其一行高的 Markdown
  anchor fragment；悬停命中不得只相信 `textLayoutFragment(for:)` 的点查询，而要在
  已布局的 viewport fragments 中检查图片 overlay 的真实矩形。拖动期间不改变
  `.fragmentOverlay` 的 bounds、不触发 TextKit 逐帧重排，也不连续改写文本。
  松手后通过标准可撤销编辑把
  宽度写成 Obsidian 兼容的 `![说明|480](路径)`；解析、编辑预览与阅读 HTML 共用
  该宽度，高度未声明时保持原图比例。普通 `![说明](路径)` 仍保持标准 Markdown；
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
  选择范围、字体高度与闪烁计时；不能依赖该视图的 `.automatic` 模式自行激活。连续
  换行产生的空段落可能没有 TextKit 2 fragment，此时从前一空行推导位置并按有效字体
  缩短，不能退回上一段 fragment 或整行框。
- 文档以换行符结尾时，TextKit 2 会把最终空行吸收到前一个片段；若前一个片段是
  表格末行，其绘制原点会丢失正常首行缩进。`DecoratedTextLayoutFragment` 只对
  这个末行场景补偿单元格内边距，避免文字、竖线和底线整体左移。
- 文档不以换行符结尾时，TextKit 2 可能为合法的 EOF 文本位置返回 `nil` fragment；
  短光标在这个场景借用前一个字符的 fragment 计算同一行的末尾位置，但仍以 EOF
  location 求横坐标。带末尾换行的空段落继续走独立的 phantom-line fallback，不能
  混用前一行几何。

这些展示属性均不改变原始 Markdown 字符串。

## 6. 阅读模式与导出

阅读模式使用独立的 `WKWebView`，由 `DocumentHTML` 与 `HTMLRenderer` 将同一份 Markdown 解析结果转换为带主题的 HTML。PDF 导出与打印复用同一条 HTML 渲染路径。

阅读环境默认禁用 JavaScript，并对原始 HTML、外部链接和远程图片执行限制。数学公式、图标和允许的本地资源会转换为内联资源。只有忽略空白后独占段落的
`$$…$$` 才输出块公式；正文中的 `$$…$$` 使用 display 模式渲染但保持行内流，
代码 span 或 fenced code 中的美元符号始终按字面量保留。

阅读模式的代码语言标签与原生复制入口组成代码块右上控件组；标签保持信息语义，
长名称在窄宽度下截断，复制按钮在悬停或键盘聚焦时显示且不会覆盖代码。按钮只注入交互式
`ReadModeWebView`，不会进入共用 HTML 路径上的 PDF、打印或 Quick Look 输出；点击
通过 `x-floralmd-copy:` 私有导航 scheme 传递 UTF-8 代码并由导航代理取消页面跳转、
写入原生剪贴板。页面脚本仍由 `allowsContentJavaScript = false` 与 CSP 禁用；复制后
的可见及无障碍反馈只使用宿主注入的静态 JavaScript，并从已转义的宿主标签属性读取
本地化文案，不把 Markdown 内容拼入脚本。

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

YAML front matter 与多块 `%%` 注释在 Read 解析前隐藏；预处理会为每个被隐藏的块
保留一个空结构行，并维护“渲染行 → 原始源码行”映射，避免相邻正文被 CommonMark
合并，也避免 `floralmd-l<原始行>` 锚点漂移。`#tag` 在两个后端显示为强调标签，
尾部 `^block-id` 作为导航元数据在 Read 中隐藏。非图片 `![[target]]` 由共享的
`AttachmentKind` 区分 PDF、音频、视频、Markdown/笔记与未知附件；Edit 继续把
原始 Markdown 内容字符显示为可编辑、可选中的 source-backed 标签，只添加分类颜色、
语义属性与中英文说明，Read 输出同类颜色、可见分类前缀和 `aria-label`。两者都明确
标注暂不支持预览，不创建附件、图片 overlay 或文件所有权，也不在此层嵌入外部内容。

页内 `[[#heading]]` 与 `[[#^block-id]]` 共用 wikilink 路由。Edit 使用当前
`Block` / `SyntaxHighlighter` 结果求原始 UTF-16 位置，再走 TextKit 2 的既有
selection 与滚动入口；Read 先求同一目标的原始源码行，再滚动自身 WebView 的
`floralmd-l<原始行>` 锚点，不能只移动被隐藏的编辑器。跨文件目标仍由直接文件
解析路径打开，并在新文档中应用相同 anchor 规则。阅读 HTML 的链接必须显式声明
`cursor: pointer`；WKWebView 不保证为 `x-floralmd-wiki:` 等私有 scheme 自动使用
手型光标。回归测试需实际加载 WKWebView、激活链接并观察 delegate 回调与 DOM
滚动，不能只分别断言 href、selector 或目标源码行。

Edit 模式的链接保留文本编辑语义：普通悬停与点击继续使用 I-beam 并放置光标，
只有按住 Command 时才切换为手型并允许跳转。链接悬停稳定 450 ms 后显示不接收
鼠标事件的轻量 AppKit 提示；点击会立即隐藏提示，同一跨行链接内移动只重定位而不
反复闪烁。同一文案也作为编辑器的 accessibility help。跟踪区只维护当前 hover
命中；`flagsChanged(with:)` 在鼠标不动时同步 Command 按下/松开的 cursor rect 与
当前光标，滚动后则按窗口当前鼠标位置重新命中。这里不得使用全局
`NSCursor.push/pop`，否则 modifier、tracking-area 与 cursor-rect 生命周期交错时
容易留下不平衡的光标栈。

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
- Git 面板读取工作区状态，并为符合条件的当前 Markdown 文件提供一次性本地提交：
  `Document` 先通过标准 `NSDocument.save` 路径提交输入法文本、写盘并核对磁盘内容，
  再由异步 `GitCurrentFileCommitService` 重新检查分支、进行中的 Git 操作和目标文件状态，
  最终只执行 `git commit --only -- <path>`。未跟踪文件只对目标路径临时执行
  `git add -N -- <path>`，失败时也只清理该路径，因此其他文件原有的 staged/unstaged
  状态不进入快照或重写流程。该入口尊重仓库 hooks，不使用 `--no-verify`，只创建本地
  commit，永不 push；冲突、删除、忽略、无变化、detached HEAD 与
  merge/rebase/cherry-pick 等不安全状态都会停止；
- Git 面板的 `History` 保持只读：它在后台调用
  `/usr/bin/git`，按拓扑顺序读取 `HEAD` 与本地分支可达的最近 80 个提交。
  `GitHistorySnapshot` 保存提交、引用和 HEAD 元数据，`GitGraphLayout` 在 Swift
  模型层分配分支与合并 lane，跨 lane 连接由 `GitGraphGeometry` 生成保持两端纵向
  切线的三次贝塞尔曲线；AppKit 行视图只负责绘制和选择。当前提交在未选中时也显示
  独立 `HEAD` 标签，分支名与提交信息按可用宽度截断。提交弹窗仅显示作者、时间、
  完整哈希、父提交和本地分支，并可复制哈希，不执行 diff、checkout、提交或推送；
- 文件/Git 侧栏默认宽度为 248pt，可从右侧分隔边缘拖动到 220–420pt，并同时受窗口
  宽度 45% 上限约束。`DocumentSidebarSessionState` 保存当前标签会话的展开宽度、主模式
  与 Git 子模式，因此折叠、模式切换、窗口 resize 和原生标签切换不会重置用户布局；
- 图片仍是普通 Markdown 引用与磁盘文件，不进入编辑器存储。格式菜单可选择现有
  图片并按设置写入绝对或相对路径；粘贴图片只拦截可转为 PNG 的剪贴板内容，弹出
  带可编辑时间前缀的命名框，将文件保存到当前 Markdown 同目录下配置的相对文件夹
  （默认 `assets/`），再通过标准编辑管线插入引用。普通文本粘贴继续交给
  `NSTextView`，撤销只撤销 Markdown 编辑，不删除已经保存的图片文件。图片悬停时
  可从右下角等比例拖动，松手后只更新同一条引用中的 Obsidian 兼容宽度后缀，不把
  图片或尺寸放进旁路数据库；
- Git 仓库根目录探测在主线程同步执行，因此必须基于稳定的文件系统路径做有界
  向上遍历；不能依赖 bookmark 或 Save As 产生的 `URL` 在卷根处自行稳定。
- 语义缩略图展示标题、列表、代码、Git 改动、光标和视口位置。其纵轴统一使用
  源码 UTF-16 位置与按当前正文列宽估算的语义换行行：短文档保持自然行距并只占
  顶部所需高度，语义行总高度超过可用区域后才整体压缩。Git 标记、光标和
  TextKit 2 `viewportRange` 都转换到同一坐标；点击或拖动再反向得到源码位置，
  只布局目标片段并有限次收敛正文落点，不按 `document.bounds.height` 比例滚动，
  也不枚举或信任全部离屏 fragment 的估算 y 坐标；
- 原生 `NSDocument` 窗口标签负责多文档切换；
- `⌘N` 通过隐藏创建未命名文档、显式加入当前普通文档标签组后再显示，不能依赖
  macOS 的“打开文稿时首选标签页”设置；没有普通文档窗口时才创建首个独立窗口。
  这条 `display: false` 路径不会调用 `showWindows()`，因此加载 pending content 后
  必须显式刷新未命名空白欢迎层，不能保留视图初始化时的隐藏状态；
  `⌘⇧N` 明确新建独立窗口：首次显示期间临时禁用自动并组，显示完成后立即恢复普通
  标签能力。快速记录继续永久禁止自动并入普通文档标签组；
- `⌘O` 默认把新文件加入触发命令时所在文档的原生标签组，文件目录或 Git 仓库不参与
  窗口分组；若当时没有可用文档窗口则创建独立窗口。文件菜单另提供无默认快捷键的
  “在新窗口中打开…”；已打开文件只激活其现有窗口或标签，不跨标签组搬移。Finder、
  命令行与启动文件请求继续遵循标准 `NSDocument` 打开流程；
- 普通本地文件成功打开后由 `RecentDocumentHistory` 写回
  `NSDocumentController` 的系统最近文档列表；`DocumentController` 明确声明与生产
  shared file list 一致的五项上限，避免不声明文档类型的隔离 Debug 身份得到默认零值。
  适配层只在 AppKit 尚未反映异步写入时保留进程内的待提交快照，系统列表一旦追平即
  回到直接读取系统值。菜单展开时按该系统列表上限实时去重，并
  移除已删除、移动或不可读的 URL。最近项与 `⌘O` 共用当前标签组语义，“清除菜单”
  直接清空同一系统列表。聚焦文本视图会先消费 `Control-R`，因此应用级本地按键
  monitor 只拦截这个精确 chord，并打开居中的最近文件选择器；选择器显示文件名与
  父目录路径，且与命令面板中的“最近打开”命令共用同一入口。文件菜单仍保留原生
  最近项目子菜单；
- 原生标签栏出现或消失时，AppKit 可能只改变 `contentView` 高度而不发送
  `NSWindow.didResize`。正文表面中以 frame 定位的顶部悬浮控件必须使用顶部锚定的
  autoresizing 或约束；否则新文件并入标签组后会保留旧 Y 坐标并被标签栏裁切。
- 应用仍在运行但没有可见文档窗口时，Dock 再激活完全交给 AppKit 的标准
  document-based reopen 流程创建至多一个未命名文档；
  `applicationShouldHandleReopen` 不得在返回 `true` 的同时手动调用
  `newDocument`，否则一次用户意图会有两个创建所有者。启动时打开已有文件、
  Finder 打开文件和窗口恢复也必须先于默认未命名创建，不能附带空白窗口。命令行
  文件请求只识别位置参数；`-ApplePersistenceIgnoreState YES`、诊断参数和其他
  UserDefaults 键值对不属于文件路径，不能误抑制默认未命名窗口；
- 欢迎提示是语义为空的未保存未命名文档上的轻量窗口层，不是 Markdown 内容或独立
  首页。冷启动、`Cmd-N` 与快速记录共用同一动态状态：`fileURL == nil`、没有 marked
  text，且 `UntitledDocumentContentPolicy` 判定正文为空时显示；输入或 IME 组合一开始
  立即隐藏，删除回语义空白或取消组合后重新显示；一旦取得 `fileURL`，即使正文为空也
  永不显示。它复用 `DocumentController` 的系统最近文件来源与当前标签组打开语义；
  实际输入提示贴近编辑器插入点，居中的 `FloralMD` 水印与文件导航不伪装成输入框。
  为保持编辑器第一响应者，透明欢迎视图位于编辑器前方但只让最近文件与“打开文件”
  控件参与命中，其他区域返回 `nil` 透传。欢迎层及其控件不注册 cursor rect，编辑器
  因而在整个表面独占连续的 I-beam；可点击性由整行即时增强背景、文字和图标来表达，
  避免前后视图争夺 cursor rect 而闪烁。`EditorTextView.textInputDidBegin` 只负责
  展示层的提前隐藏，
  AppKit 仍原样处理首个按键与 marked text；组合结束后的状态刷新只读取
  `rawSource` / `hasMarkedText()`，不触碰 storage；
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

用户设置保存在 `UserDefaults`。设置窗口按通用、编辑器、Markdown、快捷键、外观和高级分类；其中打字机滚动、源码显示、缩略图和 Markdown 扩展开关由 `AppSettings` 持久化，并通过 `EditorPreferenceCoordinator` 在设置、视图菜单、快捷键和所有已打开文档之间同步。每个扩展键默认开启并独立保留，汇总后的同一个 `MarkdownFeatures` 同时注入 Edit 与 Read；已关闭语法的格式菜单命令也必须禁用且不能旁路插入。图片路径写法默认使用绝对路径，也可改为相对于当前 Markdown 文件；剪贴板图片目录始终限制为 Markdown 同目录下的相对路径，默认 `assets/`。这两个图片设置只在下一次插入时读取，不改写已有文档。

设置窗口使用 AppKit `NSSplitViewController` 保持固定左侧分类导航，右侧为缓存的
`NSHostingController`；六个 SwiftUI pane 继续拥有各自的 `@AppStorage`、sheet、
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
快捷键页在输入源或覆盖变化时只递增展示刷新版本，保持整页及其搜索框、录制按钮的
SwiftUI 身份稳定；不能用 `.id(...)` 重建整个页面，否则 macOS 为文本框切换输入源
时会同步销毁 first responder，并中断搜索或正在进行的快捷键录制。

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

文档保存可选择自动或仅手动模式；自动模式默认每 2 秒保存一次，也可选择 1、5、10 或 30 秒，手动模式保留 `⌘S` 与关闭确认。未命名文档的首次自动落盘是另一项默认关闭的设置：用户选择目标文件夹后，`Document` 只从 `.editorDidSynchronizeText` 接收已同步的非空白正文，确认没有 marked text，并按同一保存间隔 debounce；到期后以可读时间戳命名，用 `O_EXCL` 原子占位避免覆盖，再通过标准 `NSDocument` `.saveAsOperation` 获得首个 `fileURL`。目标目录以 security-scoped bookmark 数据持久化并由单一访问边界解析，为未来 App Sandbox 保留迁移路径；失败会保留内存正文并停止，只有再次编辑或设置变化才重试。该目录按平铺的随手记 Inbox 使用：FloralMD 只把新文件直接写入所选目录根部，不创建日期、分类或“已整理”子目录，也不承担处理后的归档；文件仍在目录中即表示尚待用户判断去向。首次落盘成功后的周期保存仍完全由前一项设置决定。自动落盘、Quick Capture 复用、窗口脏状态与关闭审查共享 `UntitledDocumentContentPolicy`：仅当 `fileURL == nil`、没有 marked text 且正文 trim 空格与换行后为空时，文档才是可直接丢弃的空白未命名稿；已有文件即使被清空也始终保留普通文件语义。关闭窗口或 `⌘Q` 开始时先提交仍在进行的 marked text，再同步这一状态；清空会取消尚未触发的首次落盘，Undo 恢复非空正文则重新标脏并重新安排 debounce。

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

# Pole 运行逻辑

本文档梳理 Pole（SpacePolish）从启动、触发、采集文本、调用模型到写回结果的完整运行逻辑。所有结论基于当前源码，关键位置标注 `文件:行号`。

## 1. 项目概览

Pole 是一个原生 macOS 菜单栏工具：

- **双击左 Option** → 润色当前输入框文本
- **双击右 Option** → 翻译（中译英，其他语言译成简体中文）
- **同时按下左右 Option** → 适当扩写

有选区时只处理所选文字，无选区时处理输入框全文，结果写回原输入框。模型使用阿里云通义千问（OpenAI 兼容端点），API Key 存 macOS 钥匙串。

**进程模型**：单进程菜单栏应用（`LSUIElement`/accessory，无 Dock 图标），Swift 5.9 + SwiftPM，最低 macOS 13。

**Target 划分**（`Package.swift`）：

| Target | 路径 | 职责 |
|---|---|---|
| `PoleCore` | `Sources/Pole` | 全部运行时逻辑（31 个文件，约 1.2 万行） |
| `PolePlatform` | `Sources/PolePlatform` | 启动入口与单实例锁 |
| `Pole`（可执行） | `Sources/PoleApp` | 仅 3 行 main，调用 `runPoleApplication()` |
| `PoleQualityEvaluation` | `Checks/QualityEvaluationMain.swift` | 真实模型质量回归（离线工具） |
| `PoleCoreTests` | `Checks/` 两个回归文件 | 单元/回归测试 |

## 2. 启动流程

入口链：`Sources/PoleApp/main.swift` → `PoleRuntime.runPoleApplication()`（`Sources/PolePlatform/PoleRuntime.swift:18`）→ `AppCoordinator`。

1. **单实例锁**：`SingleInstanceLock.acquire()` 对临时目录下 `com.spacepolish.mac.instance.lock` 做 `flock(LOCK_EX|LOCK_NB)`；拿不到锁直接 `exit(EXIT_SUCCESS)` 静默退出（`SingleInstanceLock.swift:13-28`）。
2. **NSApplication 初始化**：`setActivationPolicy(.accessory)`，挂 `PoleAppDelegate`，`applicationDidFinishLaunching` 中创建 `AppCoordinator` 并 `start()`。Info.plist 键 `PoleOpenSettingsOnLaunch` / `PoleForceDarkAppearance` 可控制启动行为。
3. **AppCoordinator 初始化**（`AppCoordinator.swift:99-134`）：创建状态栏图标（`sparkle` SF Symbol）与菜单，绑定键盘监听器的三个闭包（`isEnabled` / `maximumInterval` / `onTrigger` / `onExpand`）。
4. **start()**（`AppCoordinator.swift:136-152`）：
   - 已有 API Key → 后台 `validateStoredAPIKey()` 验证连接（`AppCoordinator.swift:1338-1383`）；
   - 无辅助功能权限 → 状态置“等待辅助功能授权”，弹系统授权框并打开设置窗口，**不启动监听**；
   - 有权限 → `startMonitor()` 启动键盘监听，并 `ConversationResolver.prewarmTextRecognition()` 预热 Vision OCR；
   - 无 API Key → 提示并打开设置窗口。
5. 应用重新激活时（`applicationDidBecomeActive`，`AppCoordinator.swift:286-293`）会刷新权限状态、补验 API Key、补启动监听。

**设置窗口**（`SettingsView.swift`）共 6 个页签：通用（API Key/模型/提示词/双击间隔/提示音）、语义库、沟通智能、优化历史、聊天对象、隐私（OCR 权限、导出/清除智能数据）。

## 3. 触发层：双击 Option 监听

`DoubleOptionMonitor`（`DoubleOptionMonitor.swift:49`）通过 `CGEvent.tapCreate` 在会话级事件流（`.cgSessionEventTap`）监听 `keyDown` 与 `flagsChanged` 两类事件，只观察、不拦截。

**按键识别**：

- keyCode 58 = 左 Option，61 = 右 Option（`OptionKeySide`，`DoubleOptionMonitor.swift:4-18`）。
- **双击判定**：`DoubleOptionSequenceTracker`（:20-47）——同侧 Option 两次完整按下-松开、间隔 ≤ `triggerInterval`（默认 1.2s，可在设置中调 0.5–2.0s）即触发；期间出现任何其他 `keyDown`、带 Command/Control/Shift/Fn 的组合键、或双侧 Option 混按，计数立即清零。
- **扩写组合**：一侧 Option 已按住时再按另一侧（`expandChordPending`），两侧都松开后触发 `onExpand`；若按住期间按了其他键（如 Option+Tab），作废（`optionChordUsed`）。
- event tap 被系统超时/用户禁用（`tapDisabledByTimeout/UserInput`）时自动重新 enable（:89-94）。
- 整体门控 `isEnabled = model.isEnabled && !model.isProcessing`（`AppCoordinator.swift:114-117`）：暂停快捷键或正在处理时不触发；处理中也不接受新触发（`handleTrigger` 开头 `guard !model.isProcessing`）。

**菜单触发**：状态栏菜单每次打开时重建（`rebuildMenu`，`AppCoordinator.swift:158-222`）：状态行、暂停/启用 Option 快捷键、适当扩写当前文本、设置、评价最近一次优化（24h 内有成功润色才出现）、辅助功能授权入口（未授权时）、构建信息、退出。菜单点“适当扩写”会延迟 0.12s 再触发，等菜单关闭、焦点回到原输入框（:235-241）。

## 4. 主流程总览

一次触发（以润色为例）的完整链路：

```
双击 Option / 菜单
  └─ AppCoordinator.handleTrigger                     (AppCoordinator.swift:339)
       ├─ 终端黑名单检查（RewriteTargetSafetyPolicy）→ 命中即 HUD 提示并返回
       ├─ 进度指示器先显示在鼠标位置（showFallback）
       ├─ API 可用性检查（canUseAPI）
       ├─ rewriteCoordinator.beginRequest → 生成 requestID，开启一次请求生命周期
       ├─ 创建 RewritePerformanceTrace（性能埋点）
       └─ 异步任务：textIOService.captureTargetText() 采集文本
            └─ completeTriggerCapture                (AppCoordinator.swift:402)
                 ├─ RewriteInputPolicy.validate 长度校验（4000/12000）
                 ├─ rewriteCoordinator.monitor 启动目标监控（自动取消）
                 ├─ polish/expand：ConversationContextService 解析当前会话
                 │    └─ handlePolishTrigger          (AppCoordinator.swift:468)
                 │         ├─ 自适应预检：自然完整短文本 → 不发请求，直接“无需修改”
                 │         ├─ 非聊天应用 → beginPolish(relationship: nil)
                 │         └─ 聊天应用：已有画像 → helper 历史分析 → 称谓推断 → 通用语气
                 │              └─ beginPolish         (AppCoordinator.swift:747)
                 │                   ├─ 声音画像 / 沟通意图 / 关系维度 → CommunicationPolicy
                 │                   ├─ expand：ContextualExpansionPlanner 生成扩写计划
                 │                   └─ rewritePrompt 组装提示词 → beginRewrite
                 └─ translate：固定提示词直接 beginRewrite（无会话解析）

beginRewrite                                   (AppCoordinator.swift:925)
  └─ 异步任务：
       ├─ QwenClient.optimize 首次模型请求
       ├─ RewritePipeline.audit 五项本地检查（polish/expand 才有）
       │    └─ 不通过 → 带问题清单重试一次 → 再审计 → 仍不过 → 报错不写回
       ├─ 写回前校验：请求仍当前 + 会话未切换 + prepareForCommit 停监控
       ├─ textIOService.replace 写回（AX 或键盘粘贴）
       ├─ 光标复查（1.35s 稳定窗口，异步进行）
       ├─ polish 且开启学习 → recordRewrite 写入加密历史
       └─ completeRewrite：结果动画 + 提示音 + 性能日志收尾 + 状态归位
```

任一环节失败或检测到外部变化（见 5.2），走取消/失败路径：进度指示器失败动画、状态栏显示原因、不写回或已写回则不留迟到结果。

## 5. 各阶段详解

### 5.1 文本采集

所有 AX/键盘 I/O 封装在 `AccessibilityTextIOService`，跑在串行队列 `com.spacepolish.text-io`，避免合成按键等待和剪贴板轮询卡住主线程 UI（`TextServices.swift:15-56`）。

**产出** `CapturedTextContext`（`TextEditing.swift:309-341`）：`target`（`.accessibility(AXUIElement)` 或 `.keyboard(pid)`）、全文 `capturedText`、`cursorUTF16`、`replacementRange`、送模型的 `sourceText`、`isExplicitSelection`。写回时凭 `target` 选择写回路径。

**AX 路径**（`captureUsingAccessibility`，`TextEditing.swift:576-638`）：

1. `AXUIElementCreateSystemWide` 取系统焦点元素；取不到 → `noFocusedTextField`；
2. `TextInputSafety.validate` 查 `AXSubrole == kAXSecureTextFieldSubrole` → 密码/安全输入框拒绝（`TextEditing.swift:270-307`）；
3. 读 `kAXValueAttribute` 全文、`kAXSelectedTextRangeAttribute` 选区；
4. `TextSelectionResolver.resolve`（:88-135）解析选区：AX range 与选中文字必须一致；不一致时用复制的选中文本在全文中**唯一**定位，出现两次即拒绝；全部失败抛 `selectionUnavailable`——**绝不把选区不确定变成全文改写**；
5. `TextRangePlanner.plan`（:59-86）：有选区 replacementRange=选区；无选区=全文；纯空白拒绝。

**键盘/剪贴板回退**（`KeyboardTextFallback`，`TextEditing.swift:1001-1479`）：AX 拿不到文本时按 `KeyboardFallbackPolicy` 判定是否降级（:228-268）——`noFocusedTextField`/`unsupportedTextField` 对所有非终端应用重试；选区类错误仅对自定义编辑器名单（微信、企业微信、Codex）重试。步骤：

1. 写哨兵串 `Pole-selection-<UUID>`，合成 Cmd+C，轮询剪贴板 `changeCount`（10ms 间隔，0.18s 超时）读选区；
2. 读全文：合成 Cmd+A → 写哨兵 `Pole-<UUID>` → Cmd+C（0.8s 超时）；忽略合成按键的应用走**菜单回退**：经 AX 遍历菜单栏找“全选/Select All”“拷贝/Copy”执行；
3. 读完恢复原选区（优先 AX 写 range，其次模拟方向键，偏移 ≤1000 字符才按键恢复）；
4. `ClipboardTransaction`（`ClipboardTransaction.swift:10-69`）包裹整个过程：进入时快照原剪贴板全部内容，写入时附带专属 marker type；恢复时仅当 changeCount 未变且 marker 仍在才回写——用户期间复制了新内容则不动剪贴板。

**长度限制**：`RewriteInputPolicy`（`TextEditing.swift:13-29`）全文 ≤4,000、选区 ≤12,000（Swift Character 计数），在编排层 `completeTriggerCapture` 执行（`AppCoordinator.swift:410-428`）——采集成功后、拉会话历史和调 API 之前，超限即终止（trace 记 `input_rejected`）。

**触发前置守卫**：

- 终端黑名单（`RewriteTargetSafetyPolicy`，`ApplicationContext.swift:81-103`）：Terminal、iTerm2、Warp、WezTerm、Alacritty、Ghostty、Kitty、Hyper，在 `handleTrigger` 最前面拦截，避免模拟粘贴把多行结果当命令执行；
- 自身 `com.spacepolish.mac` 排除在键盘回退之外；
- 每个合成按键前 `ensureFrontmost` 确认目标进程仍在前台。

### 5.2 请求生命周期与自动取消

`RewriteCoordinator`（`RewriteCoordinator.swift:35-111`）用 UUID `requestID` 管理“当前请求”：`beginRequest` 取消上一个请求并发新 ID；`attach` 绑定异步任务；`isCurrent` 供各阶段确认自己没过期；`prepareForCommit` 写回前停监控；`finish/cancel` 收尾。

采集完成后启动 `RewriteTargetMonitor`（:113-208）：

- `AXObserver` 监听目标应用：焦点窗口变化、焦点元素变化、目标元素 `kAXValueChanged`、`kAXUIElementDestroyed`；
- `NSWorkspace.didActivateApplicationNotification` 监听前台应用切换。

四类取消原因（`:5-32`）：`paused`（用户暂停快捷键）、`applicationChanged`（切了前台应用）、`targetChanged`（窗口/焦点输入框变了）、`textChanged`（文本被改）。任一发生 → 取消任务、进度指示器失败态、状态栏给出中文原因（如“输入内容已变化，未写入优化结果”），**迟到结果绝不写回**。

另外在拉 helper 历史等耗时步骤前后、写回前，还会显式调用 `textIOService.isCurrent(context)` 复查（AX 目标比对前台 pid + 当前文本等于捕获文本；键盘目标仅比对 pid），不等抛 `textChangedWhileWaiting`。

### 5.3 会话识别（仅 polish/expand）

翻译完全不做会话识别。润色/扩写在采集后先 `ConversationContextService.resolveCurrentConversation()` 产出 `ConversationSnapshot`。

**只有聊天类应用参与**（`ApplicationContextClassifier`，`ApplicationContext.swift:105-203`）：微信、企业微信、信息、QQ、钉钉、飞书/Lark、Slack、Teams、Telegram、WhatsApp、Discord、Signal 等 14 个 Bundle ID 归为 `.messaging`，其余应用（AI 助手/邮件/开发/文档/通用）直接用各自角色规则，不识别会话。

**标题候选两级**（`ConversationResolver`，`ConversationContext.swift:542-829`）：

1. **AX 读取**：窗口 `AXTitle`（置信度 0.96）；或在窗口顶部 28% 区域内 DFS 扫描 `AXStaticText`，按居中度/靠顶度打分（≤0.95）；
2. **OCR 回退**：AX 拿不到 ≥0.85 的候选、且用户已授屏幕录制权限时，把 AX 窗口匹配到 `CGWindowID`，截取窗口顶部标题区，用 `VNRecognizeTextRequest`（zh-Hans/en-US）识别；OCR 置信度 = Vision 置信度×0.72 + 居中度×0.20 + 靠顶度×0.08。未授权时静默跳过。

标题经 `ConversationTitleNormalizer` 归一化并剔除“微信”“消息”“new chat”、时间日期等界面元数据。**自动绑定阈值 0.85**；识别不出可用会话时不打断用户，直接用通用聊天语气（`requestRelationshipOrUseGeneric`，`AppCoordinator.swift:731-745`）。

### 5.4 关系画像与聊天历史 helper

聊天应用的润色按以下顺序确定“对方是谁”（`handlePolishTrigger`，`AppCoordinator.swift:468-553`）：

1. **已有画像**且 24h 内分析过 → 直接用；
2. **helper 历史分析**：用户配置了已确认的聊天历史 helper、且（本次是扩写 或 画像超过 24h 未刷新）→ `prepareHistoryContext`（:555-729）：`ExternalHelperProvider` 依次调 `capabilities` → `sessions`（按归一化标题唯一匹配会话，0 个/多个都视为失败）→ `history`（刷新画像取 200 条/30 天，否则 30 条/7 天）→ 后台跑 `RelationshipAnalyzer`（和扩写用的 `RecentConversationAnalyzer`）→ 写回前复查文本/会话未变 → `applyAnalysis` 更新画像后继续。helper 任一步失败自动降级到后续通道；
3. **称谓推断**：`ConversationRoleInference` 整词匹配词表（老婆/老公/爸妈/家人群 → 朋友家人；老板/领导/主管 → 上级；客户/甲方 → 客户；同事/搭档 → 同事），**恰好命中一个角色**才建档，置信度 0.86（`ConversationContext.swift:245-311`）；
4. 都不行 → 通用聊天语气（relationship = nil）。

**关系画像** `RelationshipProfile`（`CommunicationIntelligence.swift:114-188`）：五角色概率、置信度、证据（≤5 条）、五维关系指标（权力距离/熟悉度/正式度/直接度/详细度）、`lastAnalyzedAt`、`pendingChange`。

**关系变化**需同一结论被观察 2 次且由用户在“聊天对象”设置页点“确认”才生效（`applyAnalysis`/`confirmPendingChange`，`CommunicationIntelligence.swift:744-817`）。

**helper 协议与安全边界**（`ExternalConversationHelper.swift`、`HelperIdentity.swift`）：

- 用户在设置页选择本地可执行文件 → 计算 SHA-256 + 代码签名状态 → 弹窗明示“readOnly 只是 helper 自我声明” → 用户确认后身份 JSON 存 UserDefaults、URL 存 security-scoped bookmark；
- 每次运行前重新哈希比对，文件变了要求重新确认；
- 协议版本 1 三命令：`capabilities --json`（要求 `readOnly: true`，否则拒绝运行）、`sessions --limit N --json`、`history --conversation-id … --limit … --days … --json`；
- 每次调用 10 秒超时、stdout 上限 2 MiB，超时先 terminate 再 SIGKILL；
- helper 返回的原始消息**只在内存中**用于分析，落盘的只有派生画像（AES-GCM 加密）。

**扩写上下文缓存**：`RecentConversationAnalyzer` 从最近一条收到的消息推断问题类型（时间/原因/可行性/进展/处理方式/确认），结果按会话缓存 120 秒（`RecentContextCache`，`ContextualExpansion.swift:266-293`），供扩写计划使用。

### 5.5 提示词组装

`beginPolish`（`AppCoordinator.swift:747-808`）汇总四类上下文，`rewritePrompt`（:810-855）组装最终 system 提示词：

1. **基础规则**：润色 = 默认提示词（保真→编辑→定调→控幅→并列五步法，`PromptPolicy.currentDefault`）+ 中文编辑检查清单；用户自定义提示词可覆盖，旧版默认值自动升级。扩写 = 独立的 `ExpansionPolicy` 提示词（补全省略成分与逻辑连接，不新增事实）。翻译 = 固定 `TranslationPolicy.prompt`，**不拼任何场景指令**。
2. **应用场景**：`ApplicationWritingRole` 七种（Codex 的 `aiDevelopmentAssistant`、ChatGPT 的 `aiAssistant`、`messaging`、`email`、`development`、`document`、`generic`），按前台 Bundle ID 分类，各带一段表达规则（`ApplicationContext.swift:3-65`）。
3. **沟通策略**（仅聊天）：`CommunicationPolicy.modelInstruction`（`CommunicationIntelligence.swift:365-415`）——口吻护栏 + 沟通意图（关键词规则推断）+ 关系角色/置信度/权力距离/熟悉度 + 用户语气词白名单（前 6 个）+ 声音画像档位摘要（句长/正式度/直接度）+ 该会话自定义规则（会话名替换为“对方”做匿名化）。
4. **专业语义库**：六库（光学与激光、制造与质量、项目与交付、采购与商务、嵌入式与硬件、软件开发，`SemanticLibrary.swift`）在本机对原文做带权 cue 词匹配，得分 ≥2 算命中，**最多取前 3 个库**的保护规则注入（如“逐字保留 I2C/SPI 等术语”）；命中库的保护词同时交给 FactGuard 做逐字保留校验。可在设置页逐项关闭。

**长度预算** `RewriteLengthBudget`（`PromptPolicy.swift:19-59`）：上限 = `min(max(下限, ⌈字数×maxRatio⌉+slack), 字数+绝对增量上限)`。润色按自适应强度取 1.25/1.35/1.65 倍上限；扩写固定 1.15–1.60 倍、绝对增量 ≤160 字。预算不直接写进提示词，而是作为参数传给本地防线强制执行。

**自适应预检**：`AdaptivePolishPolicy.plan` 判定原文为自然完整的短回复（无需改动）时，**根本不发模型请求**，0.08s 后直接走“无需修改”完成路径（`AppCoordinator.swift:945-960`）；其余按 none/light/standard/strong 限定修改幅度。

**扩写计划** `ContextualExpansionPlanner.plan`（`ContextualExpansion.swift:135-189`）：按原文特征选操作集合（连接分句/澄清指代/拆长句/并列项编号/补全省略），结合最近收到消息的问题类型生成针对性约束（如原文没时间信息则禁止添加日期）；`requiresVisibleExpansion` 为 false 时明确允许逐字保持原文。

### 5.6 模型请求

`QwenClient`（`QwenClient.swift`）：

- 端点 `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`；默认模型 `qwen3.7-plus`（可选 `qwen3.6-flash`），`temperature 0.5`，`enable_thinking: false`（关闭思考模式优先即时写回）；
- messages 固定两条：system = 组装好的提示词，user = 原文；`stream: false`；`max_completion_tokens = min(2048, max(128, 字数×2+64))`；
- **超时三档**（`requestTimeout`，:196-208）：≤280 字 20s，≤1200 字 30s，更长 45s；纠错重试缩短为 2/3、下限 12s；
- API Key 验证走 `GET /models`（12s 超时），401/403 判为认证失败并检查模型列表是否含所选模型（`validateAPIKey`，:15-38）；运行中遇到 401/403 会把 Key 标记失效；
- **结果本地清洗** `RewriteResultPolicy`（:211-325）：剥掉模型附加的开头标签与“优化说明/修改理由/改写要点”类解释（原文本身含这些字样时不剥）；原文尾部有“帮我润色/怎么优化”等编辑指令时把结果末尾对应句删掉；保留原文首尾边界空白；清洗后为空抛 `emptyResult`。

### 5.7 质量防线与纠错重试

仅 polish/expand 走防线；translate 单次请求直出，无审计无重试（`AppCoordinator.swift:1083-1092`）。

`RewritePipeline.audit`（`RewritePipeline.swift:40-102`）在后台并行跑五项检查，汇总为 `RewriteAuditBundle`：

- **安全** `isSafe` = FactGuard ∧ VoiceGuard ∧ RewriteAlignmentGuard
- **质量** `isQualityAccepted` = RewriteQualityGuard ∧ ContextualExpansionGuard（扩写才有）

| Guard | 检查要点（`RewriteGuards.swift`） |
|---|---|
| FactGuard 事实安全 | 受保护 token（代码/URL/路径/数字单位/日期/称谓/语义库保护词）逐字保留；否定词丢失；不确定→确定漂移；擅自新增时间/原因/承诺/责任人；关键动作词被删；先后关系丢失且大幅缩短；超长预算；开发场景命令行逐字保留 |
| VoiceGuard 口吻 | 公文话术注入；聊天场景正式度跳升超阈值（画像+0.30 且原文+0.35）；无 emoji 习惯却加 emoji；输出超原文 2 倍 |
| RewriteAlignmentGuard 对齐 | 字符多重集合保留率/新增率：保留率过低且新增率高 → 无依据大改；大幅压缩；长度比 >1.85（扩写 2.15）且新增率高 → 无依据扩写 |
| RewriteQualityGuard 成稿质量 | 原样返回但原文确有可修问题；扩写未达 1.15 倍下限；超预算；输出残留“帮我润色”类指令；引入汇报腔；短单句被分段；≥3 个并列项未按“1、2、3”列出 |
| ContextualExpansionGuard 扩写专用 | 要求可见扩写时须达下限；无分句变多/连接词变多/编号列表等证据且增量 ≤2 字 → 判定只做了同义词/语气词替换 |

**纠错重试**（`AppCoordinator.swift:1006-1081`）：首次审计不通过 → 把全部问题拼成清单追加到提示词尾部（“上一次候选未通过本地安全检查。必须修正以下问题……”）重试**一次**，并重审计。终局处置：

- 首次或重试通过 → 采用对应稿件；
- 首次安全但两次都无实质改动：原文确有改进点 → 抛 `qualityRejected` **诚实报错**（不静默写回原文冒充成功）；原文本就接近最优 → 保留原文，归类 unchanged；
- 其余 → 抛 `RewriteSafetyError.rejected` / `.qualityRejected`，状态栏显示前 2 条问题，不写回。

连续两次都得不到安全可用的改写时，宁可保留原文或明确失败。

### 5.8 写回与光标恢复

写回前在 MainActor 上三连校验（`AppCoordinator.swift:1098-1109`）：请求仍是当前 → 会话未切换（OCR 标题用宽容匹配）→ `prepareForCommit` 停掉目标监控。

**AX 写回**（`replaceUsingAccessibility`，`TextEditing.swift:700-733`）：

1. 重读当前全文，`TextCommitPlanner` 要求**当前文本 == 捕获文本**，否则 `textChangedWhileWaiting` 拒绝覆盖；
2. 首选 `kAXValue` 整值写入（避免产生可见选区）；失败则备用“设选区 + 写 `kAXSelectedText`”；两者皆败 → `readOnlyTextField`；
3. 把光标设到“替换区间末尾”。

**键盘写回**（微信等自绘编辑器；AX 写回失败且属自定义编辑器名单时也会降级到这里）：重读全文并做归一化等价校验（NFC、换行符统一、剔除零宽字符）→ `ClipboardTransaction` 写入结果 → Cmd+A 全选 → Cmd+V 粘贴 → 右方向键收拢 → 恢复原剪贴板。

**光标复查**（`scheduleFocusedCaretRecovery`，`TextEditing.swift:879-970`）：写回后在 **0.04 / 0.14 / 0.35 / 0.70 / 1.10 / 1.35s** 六个检查点复查光标。每点重新取焦点元素（Electron 应用写回后会重建 AX 节点，按 pid + 值匹配新节点）：

- 光标已在期望位置且选区为空 → 继续/结束；
- 光标被重置到开头（location == 0）或残留整段选区（微信/Chromium 常见问题）→ 重新写选区，必要时补发右方向键收拢 DOM 选区；
- 光标在其他位置 → 判定用户主动移动，立即停止干预。

### 5.9 完成收尾

- `OptimizationOutcome.classify` 区分 changed / unchanged（归一化比较）；
- **进度指示器**（`InputProgressIndicator`）：38×30 浮动面板，触发时先出现在鼠标位置，采集后锚定到输入光标右侧（取不到则以 0.04/0.12/0.24s 重试定位）；处理中三点弹跳动画，完成后按结果显示绿✓（已修改）/灰−（无需修改）/红叹号（失败），尊重“减弱动态效果”无障碍设置；
- **提示音**：完成播内置 `uisfx-minimal-complete.mp3`（缺失回退系统 “Glass”），无需修改 “Tink”，失败 “Funk”，可在设置关闭；
- **HUD**（`StatusHUD`）：仅用于“设置已保存”、安全拦截原因、输入被拒绝三类提示；
- polish 写回成功且开启“本地记录优化历史并学习我的表达”→ `recordRewrite` 写入加密历史；随后 24h 内菜单栏可对最近一次优化打五档反馈（符合/太正式/太啰嗦/不像我/事实有误，`applyFeedback` 调整本地画像，见 §6）；
- **性能日志** `RewritePerformanceTrace`：分 capture / conversation_context / history_context / first_model / first_guard / retry_model / retry_guard / writeback / total 阶段，记录动作、字符数、毫秒数、是否重试、重试类别、结果，写入统一日志（subsystem `com.spacepolish.mac`，category `rewrite-performance`），不含正文与会话名。可用 `log stream --level info --predicate 'subsystem == "com.spacepolish.mac" AND category == "rewrite-performance"'` 实时观察。

## 6. 三种动作的差异

| | 润色 polish | 翻译 translate | 扩写 expand |
|---|---|---|---|
| 触发 | 双击左 Option | 双击右 Option | 左右 Option 同按 / 菜单 |
| 会话识别 | 是 | 否 | 是 |
| 关系画像/helper | 是 | 否 | 是（另拉最近上下文做问题类型推断） |
| 提示词 | 基础 + 编辑检查 + 场景 + 语义库 + 对象规则 | 固定提示词，不加任何场景 | 独立扩写提示词 + 场景 + 扩写计划 |
| 自适应 no-op 短路 | 有 | 无 | 无 |
| 长度预算 | 按强度 1.25/1.35/1.65 倍 | 无 | 1.15–1.60 倍、增量 ≤160 字 |
| 五项防线 + 重试 | 是 | 否（单次直出） | 是（含 ContextualExpansionGuard） |
| 写入优化历史/可反馈 | 是（开关控制） | 否 | 否 |

翻译的隔离是刻意的：忠实翻译要求不掺入任何关系语气、个人风格或语义库规则。

## 7. 沟通智能：本地学习闭环

全部派生数据（关系画像、声音画像、优化历史、安全偏好、待学习样本）整体 JSON 序列化后用 CryptoKit **AES-GCM 加密**，存 `~/Library/Application Support/Pole/intelligence-v1.dat`；32 字节随机密钥存钥匙串（`CommunicationIntelligence.swift:1101-1162`）。旧版 `conversationProfiles.v1`（UserDefaults）首启自动迁移并删除。

**声音画像** `VoiceMetrics`：从文本计算平均句长、emoji 率、感叹号率、正式度/直接度/详细度三档指标、语气词白名单（“嗯/好的/收到/辛苦/哈哈……”按频次取前 8）。三条学习通道：

1. **聊天历史**：helper 拉到的本人已发消息 ≥3 条才学，全局画像 + 关系级 overlay 双写，旧样本指数衰减；
2. **被接受的优化**：仅聊天场景；**原稿占 72% 权重**、优化结果占 28%（原稿是最强身份信号）；
3. **实际发送版本回吸**：优化结果只存 SimHash 指纹（64 位 bigram + FNV-1a）不落正文，若 helper 历史中在时间窗内出现指纹相似度 ≥0.55 的已发送消息，按风格距离加权吸收用户最终发出去的版本（`CommunicationIntelligence.swift:1030-1078`）。

进入提示词的只有**不含姓名和正文的风格摘要**（语气词表 + 三个档位描述 + “只模仿稳定风格，不复用历史事实”的约束）。

**优化历史**：默认关闭；开启后每次成功润色把原文/结果/时间/应用场景/关系 ID 写入加密库，最多 200 条、保留 180 天，设置页可查看/单删/清空。五档反馈的本地调整：符合 → directness +0.01 且结果按 0.2 权重混入声音；太正式 → formality −0.08；太啰嗦 → detail −0.08、句长 ×0.92；不像我 → 原稿声音按 0.32 回混；事实有误 → `factIssueCount + 1`、允许膨胀率 −0.05（下限 1.12，回流为后续审计的 `expansionRatio` 上限）。

**隐私页**提供“导出派生画像”（不含聊天正文的 JSON）与“清除全部智能数据”（删加密库 + 删钥匙串密钥）。

## 8. 持久化一览

| 位置 | 内容 |
|---|---|
| UserDefaults | `isEnabled`、`modelName`、`prompt`、`triggerInterval`、`soundEffectsEnabled`、`historyAnalysisEnabled`、`rewriteLearningEnabled`、`enabledSemanticLibraries` + 目录版本、`conversationHelperApprovedIdentity`（helper 身份 JSON）、`conversationHelperBookmark`（security-scoped bookmark） |
| Keychain（`kSecClassGenericPassword`，service `com.spacepolish.mac`） | account `qwen-api-key`：通义千问 API Key；account `communication-intelligence-key-v1`：智能库 AES 密钥 |
| `~/Library/Application Support/Pole/intelligence-v1.dat` | AES-GCM 加密的派生数据（关系/声音/优化历史/安全偏好/待匹配指纹） |
| 内存 only | helper 原始聊天消息、OCR 图像与原文（均不落盘） |

## 9. 安全与隐私边界

- **出机数据**：仅当前待处理文本（选区或全文）+ 不含姓名/正文的场景规则与风格摘要，发往 dashscope 端点；有选区只发选区。
- **不出机**：API Key（Keychain）、会话名称、应用名、OCR 图像与原文、helper 原始消息（仅内存）、语义库命中记录、优化历史（本地加密）。
- 终端应用一律不触发；密码/安全输入框不读不写；自身 UI 不做键盘回退。
- 文本被改/焦点切换/应用切换/暂停 → 自动取消，迟到结果不写回；写回前严格比对“当前文本 == 捕获文本”。
- 这不是离线工具：触发即意味着把该段文字发给通义千问，敏感段落不要触发。

## 10. 构建与质量验证

- `./Scripts/build-app.sh` → `dist/Pole.app` 本机开发包（写入 Git commit/工作树状态/构建时间）。
- `./Scripts/build-release.sh`：正式 release，需 Developer ID + notarytool 配置，Hardened Runtime、公证、装订票据、`spctl` 验证。
- `./Scripts/run-checks.sh`：`swift test`（完整 Xcode）或等价的独立回归入口（仅 CLT 时）。
- `./Scripts/run-quality-evaluation.sh [N] [--expand N]`：`PoleQualityEvaluation` 用 Keychain 里的真实 API Key 对脱敏语料（40 条润色 / 22 条扩写）跑线上同款 prompt + 同款防线，输出逐条 PASS/FAIL 与汇总（`QualityEvaluationRunner.swift`）。

## 11. 关键文件索引

| 文件 | 职责 |
|---|---|
| `Sources/PolePlatform/PoleRuntime.swift` | 进程入口、单实例锁、NSApplication 装配 |
| `Sources/Pole/AppCoordinator.swift` | 中央调度：触发、采集、会话、请求、审计、写回、菜单 |
| `Sources/Pole/DoubleOptionMonitor.swift` | CGEvent tap 双击/组合 Option 识别 |
| `Sources/Pole/RewriteCoordinator.swift` | 请求生命周期、AXObserver 目标监控、自动取消 |
| `Sources/Pole/TextEditing.swift` | AX/键盘文本采集与写回、选区解析、光标恢复、长度策略 |
| `Sources/Pole/TextServices.swift` | 串行 text-io 队列封装、钥匙串凭据薄封装 |
| `Sources/Pole/ClipboardTransaction.swift` | 剪贴板快照/归属标记/安全恢复 |
| `Sources/Pole/QwenClient.swift` | DashScope 请求、超时、Key 验证、结果清洗 |
| `Sources/Pole/PromptPolicy.swift` | 三模式提示词、长度预算、并列项策略 |
| `Sources/Pole/RewriteGuards.swift` | 事实/口吻/对齐/成稿四道本地防线 |
| `Sources/Pole/RewritePipeline.swift` | 五项审计并行执行与汇总 |
| `Sources/Pole/SemanticLibrary.swift` | 六类专业语义库本地命中与注入 |
| `Sources/Pole/ContextualExpansion.swift` | 扩写计划、扩写审计、最近上下文缓存 |
| `Sources/Pole/ApplicationContext.swift` | 前台应用分类、场景规则、终端黑名单 |
| `Sources/Pole/ConversationContext.swift` | 会话识别（AX 标题/OCR）、称谓推断、旧版画像存储 |
| `Sources/Pole/CommunicationIntelligence.swift` | 关系画像、声音画像、优化历史、反馈学习、AES-GCM 存储 |
| `Sources/Pole/ExternalConversationHelper.swift` | helper 协议客户端（capabilities/sessions/history） |
| `Sources/Pole/HelperIdentity.swift` | helper SHA-256/签名确认与信任存储 |
| `Sources/Pole/AppModel.swift` | 状态模型与 UserDefaults 持久化 |
| `Sources/Pole/KeychainStore.swift` | 钥匙串读写 |
| `Sources/Pole/InputProgressIndicator.swift` | 光标旁进度/结果动画与提示音 |
| `Sources/Pole/StatusHUD.swift` | 顶部 HUD 提示 |
| `Sources/Pole/RewritePerformanceTrace.swift` | 分阶段性能埋点（统一日志） |
| `Sources/Pole/SettingsView.swift` | 设置窗口（6 页签） |
| `Sources/Pole/QualityEvaluationRunner.swift` | 离线质量回归执行器 |
| `Sources/Pole/SingleInstanceLock.swift` | flock 单实例锁 |

## 12. 附注

- `ConversationProfilePanel`（手动选择聊天对象的浮层）及 `showConversationProfilePanel` / `handleConversationProfileDecision` / `createManualRelationship` 链路代码完整保留，但当前触发流程中无调用方：未知会话不再打断首次润色，直接按通用聊天语气处理；关系的建立靠称谓自动推断或“聊天对象”设置页手动维护（`AppCoordinator.swift:731-745` 注释明确此设计意图）。
- `QwenClient.optimizeStructured`（JSON 结构化返回路径）与 `StructuredRewriteResult` 的元数据字段（intent/preservedClaims 等）目前只作为审计参考，FactGuard 不采信模型自报字段；线上主路径是纯文本 `optimize`。

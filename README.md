# Pole

Pole 是一个原生 macOS 菜单栏工具：连续按两次左 Option 润色，连续按两次右 Option 翻译，并把结果写回原输入框；有选区时只处理所选文字，无选区时处理输入框全文。

## 当前版本

- 原生 macOS 菜单栏应用，支持 Apple Silicon 和 Intel（在对应机器上构建）。
- 连续按两次左 Option 润色，连续按两次右 Option 翻译；间隔可在 0.5–2.0 秒之间设置，Option 组合键不会触发。
- 翻译会自动判断语言：中文译成英文，其他语言译成简体中文。
- 有选区时只优化或翻译所选文字；无选区时默认处理输入框全文。
- 通义千问 API Key 保存在 macOS 钥匙串，不写进配置文件或日志。
- 等待 API 返回时如果用户继续修改原文本，应用会拒绝覆盖新内容。
- 支持原生、浏览器、Electron 等标准文字输入框。
- 对未暴露辅助功能文本语义的自绘输入框提供通用键盘回退；读取和写回期间会暂用剪贴板，操作完成后自动恢复原剪贴板内容。
- 系统标记为密码/安全输入框的控件以及常见终端不启用键盘回退，避免读取敏感内容或覆盖命令行。
- 支持自定义提示词，以及 `qwen3.7-plus` / `qwen3.6-flash`；默认使用 `qwen3.7-plus` 并关闭思考模式。
- 左 Option 润色会先按 Bundle ID 识别前台应用：Codex、ChatGPT、邮件、开发工具和文档应用自动使用对应的场景规则，未知应用使用通用润色。
- 只有已识别的聊天客户端会继续解析当前会话：优先读取窗口辅助功能标题，读取不到时可使用本机 OCR；“老婆”“老板”“客户”“同事”等明确称谓会在本机自动匹配角色，含义不明确的新会话仍由用户首次确认。
- 聊天对象规则只影响润色，不影响右 Option 的忠实翻译；群聊和个人聊天都按独立会话保存。
- 可选接入用户自行提供的只读聊天历史 helper，在本机从最近 30 天、最多 200 条文本消息中推断关系和学习本人表达习惯；Pole 不安装 helper、不提权、不读取数据库密钥，也不修改微信。
- 关系画像包含角色概率、置信度、权力距离、熟悉度、正式度、直接度和详细度；关系发生变化时需要连续两次观察并由用户确认。
- 润色首轮直接返回文本，减少结构化输出开销；短消息首轮请求最长等待 20 秒，安全纠错重试使用更短超时，长文本仍保留最多 45 秒。随后在本机检查数字、日期、单位、路径、命令、否定关系、确定程度、新增事实和风格距离。首次结果不安全时只重试一次，仍不合格则保留原文。
- 每次处理会向 macOS 统一日志记录文本采集、会话识别、模型请求、安全检查、写回和总耗时，只包含动作类型、字符数、毫秒数、是否重试与结果，不记录正文、会话名称或 API Key。
- 聊天历史分析和成稿学习默认关闭。原始聊天仅在内存中处理，不会发送到通义千问；关系与声音画像使用 AES-GCM 加密，密钥保存在 macOS 钥匙串。
- 菜单栏可对最近一次优化反馈“符合、太正式、太啰嗦、不像我、事实有误”，反馈不保存聊天全文。

## 构建与运行

需要 macOS 13 或更高版本，以及 Xcode Command Line Tools。

```bash
chmod +x Scripts/build-app.sh
./Scripts/build-app.sh
open dist/Pole.app
```

首次启动：

1. 在弹出的系统设置中，为 Pole 打开“隐私与安全性 → 辅助功能”权限。
2. 退出并重新打开 Pole。
3. 点击菜单栏魔杖图标，打开“设置”，填写通义千问 API Key 并保存。
4. 在支持的输入框中选中文字（也可以不选），连续按两次左 Option 润色，或连续按两次右 Option 翻译。

如果希望在无法读取窗口标题的聊天软件中自动识别会话，可在“设置 → 隐私”中点击“启用 OCR 识别”，并按系统提示授予“屏幕录制”权限。Pole 只会在辅助功能识别失败时截取当前前台窗口的顶部标题区。

### 可选聊天历史 helper

Pole 只支持用户主动选择的本地可执行文件，并使用 `Process` 直接传递参数，不经过 shell。helper 必须是只读实现，并支持以下协议版本 1 命令：

```text
helper capabilities --json
helper sessions --limit 200 --json
helper history --conversation-id <opaque-id> --limit 200 --days 30 --json
```

`capabilities` 返回：

```json
{
  "protocolVersion": 1,
  "provider": "provider-name",
  "supportsSessions": true,
  "supportsHistory": true,
  "readOnly": true
}
```

`sessions` 返回 `{ "protocolVersion": 1, "status": "ok", "sessions": [...] }`，每个会话包含不透明 `id`、`title`、`type` 和可选 ISO-8601 `lastActivity`。`history` 返回相同版本和状态，以及 `messages`；每条消息包含 `id`、`conversationID`、ISO-8601 `timestamp`、`direction`（`sent` / `received`）、可选 `senderID`、`kind` 和可选 `text`。

Pole 对每次 helper 调用设置 10 秒超时和 2 MiB 输出上限，只接受 `readOnly: true` 与协议版本 1。helper 的安装、数据库访问、密钥、缓存和系统权限均不属于 Pole；连接失败、重名会话或协议不兼容时自动回退到窗口标题、OCR 和手动关系规则。

## 隐私与边界

- 有选区时只有所选文字会发送到 `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`；无选区时会发送当前输入框全文。
- 应用需要辅助功能权限，才能监听双 Option 并修改当前文本框。
- 聊天对象名称、应用名称、Bundle ID、OCR 图像和 OCR 原文只保存在本机或内存中，不会发送给通义千问，也不会写入日志或图片文件；模型只会收到不含名称的场景表达规则。
- helper 返回的原始消息只在当前分析期间保留在内存中。磁盘仅保存加密后的派生关系、声音指标和最多 24 小时的待匹配成稿指纹，不保存成稿正文。
- 已绑定对象的个人表达规则会追加到润色提示词；Pole 会移除识别到的会话名称后再发送规则。右 Option 翻译不会使用对象规则。
- 屏幕录制权限只用于本机 OCR 标题识别，且只能在设置页由用户主动请求；未授权或识别不确定时，Pole 会继续使用通用润色，不会猜测聊天对象。
- 默认使用 macOS Accessibility 文本接口。普通原生文本框，以及正确暴露辅助功能语义的浏览器/Electron 输入框可以直接处理选区或全文。
- 对未暴露文本值的自绘输入框，Pole 会尝试通用键盘与剪贴板回退。若无法可靠确定重复文字对应的选区位置，Pole 会拒绝猜测和覆盖；极少数拦截系统复制粘贴的应用仍可能不支持。
- 系统标记为密码/安全输入框的控件以及常见终端不会读取或写回。
- 这不是离线工具。不要在包含敏感信息的段落中触发，除非你接受把该段文字发送给通义千问。

## 开发验证

```bash
chmod +x Scripts/run-checks.sh
./Scripts/run-checks.sh
swift build -c release
```

需要定位实际耗时时，可在终端运行以下只读日志命令后触发一次润色：

```bash
log stream --level info --predicate 'subsystem == "com.spacepolish.mac" AND category == "rewrite-performance"'
```

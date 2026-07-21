# SpacePolish

SpacePolish 是一个原生 macOS 菜单栏工具：在当前输入段落末尾连续按两次左 Option 润色，连续按两次右 Option 翻译，并把结果写回原输入框。

## 当前版本

- 原生 macOS 菜单栏应用，支持 Apple Silicon 和 Intel（在对应机器上构建）。
- 连续按两次左 Option 润色，连续按两次右 Option 翻译；间隔可在 0.5–2.0 秒之间设置，Option 组合键不会触发。
- 翻译会自动判断语言：中文译成英文，其他语言译成简体中文。
- 默认只优化光标所在段落，保留其他段落。
- 通义千问 API Key 保存在 macOS 钥匙串，不写进配置文件或日志。
- 等待 API 返回时如果用户继续修改原文本，应用会拒绝覆盖新内容。
- 支持原生、浏览器、Electron 等标准文字输入框。
- 对未暴露辅助功能文本语义的自绘输入框提供通用键盘回退；读取和写回期间会暂用剪贴板，操作完成后自动恢复原剪贴板内容。
- 系统标记为密码/安全输入框的控件以及常见终端不启用键盘回退，避免读取敏感内容或覆盖命令行。
- 支持自定义提示词，以及 `qwen3.7-plus` / `qwen3.6-flash`；默认使用 `qwen3.7-plus` 并关闭思考模式。

## 构建与运行

需要 macOS 13 或更高版本，以及 Xcode Command Line Tools。

```bash
chmod +x Scripts/build-app.sh
./Scripts/build-app.sh
open dist/SpacePolish.app
```

首次启动：

1. 在弹出的系统设置中，为 SpacePolish 打开“隐私与安全性 → 辅助功能”权限。
2. 退出并重新打开 SpacePolish。
3. 点击菜单栏魔杖图标，打开“设置”，填写通义千问 API Key 并保存。
4. 在支持的输入框中输入一段文字，连续按两次左 Option 润色，或连续按两次右 Option 翻译。

## 隐私与边界

- 只有触发时的当前段落会发送到 `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`。
- 应用需要辅助功能权限，才能监听双 Option 并修改当前文本框。
- 默认使用 macOS Accessibility 文本接口。普通原生文本框，以及正确暴露辅助功能语义的浏览器/Electron 输入框可以直接优化当前段落。
- 对未暴露文本值的自绘输入框，SpacePolish 会尝试通用键盘与剪贴板回退。此时触发位置必须在整个输入框末尾；极少数拦截系统复制粘贴的应用仍可能不支持。
- 系统标记为密码/安全输入框的控件以及常见终端不会读取或写回。
- 这不是离线工具。不要在包含敏感信息的段落中触发，除非你接受把该段文字发送给通义千问。

## 开发验证

```bash
chmod +x Scripts/run-checks.sh
./Scripts/run-checks.sh
swift build -c release
```

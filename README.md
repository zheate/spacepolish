# SpacePolish

SpacePolish 是一个原生 macOS 菜单栏工具：在当前输入段落末尾连续输入三个空格，它会调用 DeepSeek 优化表达，并把结果写回原输入框。

## 当前版本

- 原生 macOS 菜单栏应用，支持 Apple Silicon 和 Intel（在对应机器上构建）。
- 连续三个空格触发，间隔可在 0.5–2.0 秒之间设置。
- 默认只优化光标所在段落，保留其他段落。
- DeepSeek API Key 保存在 macOS 钥匙串，不写进配置文件或日志。
- 等待 API 返回时如果用户继续修改原文本，应用会拒绝覆盖新内容。
- 支持微信 4.x 自绘输入框；读取和写回期间会暂用剪贴板，操作完成后自动恢复原剪贴板内容。
- 支持自定义提示词，以及 `deepseek-chat` / `deepseek-reasoner`。

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
3. 点击菜单栏魔杖图标，打开“设置”，填写 DeepSeek API Key 并保存。
4. 在支持的输入框中输入一段文字，紧接着输入三个空格。

## 隐私与边界

- 只有触发时的当前段落会发送到 `https://api.deepseek.com/chat/completions`。
- 应用需要辅助功能权限，才能监听三空格并修改当前文本框。
- 默认使用 macOS Accessibility 文本接口。普通原生文本框，以及正确暴露辅助功能语义的浏览器/Electron 输入框可用；微信 4.x 使用受限的键盘与剪贴板回退，其他未暴露文本值的自绘输入框仍可能不支持。
- 这不是离线工具。不要在包含敏感信息的段落中触发，除非你接受把该段文字发送给 DeepSeek。

## 开发验证

```bash
chmod +x Scripts/run-checks.sh
./Scripts/run-checks.sh
swift build -c release
```

import AppKit

final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private let onSave: () -> Void
    private let onRequestPermission: () -> Void
    private let onRequestScreenCapturePermission: () -> Void

    private let apiKeyField = NSSecureTextField()
    private let modelPicker = NSPopUpButton()
    private let promptTextView = NSTextView()
    private let intervalSlider = NSSlider(value: 1.2, minValue: 0.5, maxValue: 2.0, target: nil, action: nil)
    private let intervalLabel = NSTextField(labelWithString: "1.2 秒")
    private let permissionLabel = NSTextField(labelWithString: "")
    private let screenCapturePermissionLabel = NSTextField(labelWithString: "")
    private let helperPathLabel = NSTextField(wrappingLabelWithString: "未配置本地 helper")
    private let helperStatusLabel = NSTextField(labelWithString: "")
    private let historyCheckbox = NSButton(checkboxWithTitle: "允许分析当前会话历史", target: nil, action: nil)
    private let learningCheckbox = NSButton(checkboxWithTitle: "本地记录优化历史并学习我的表达", target: nil, action: nil)
    private let voiceSummaryLabel = NSTextField(wrappingLabelWithString: "尚未建立用户声音画像")
    private let conversationProfilesView: ConversationProfilesSettingsView
    private let rewriteHistoryView: RewriteHistorySettingsView

    init(
        model: AppModel,
        onSave: @escaping () -> Void,
        onRequestPermission: @escaping () -> Void,
        onRequestScreenCapturePermission: @escaping () -> Void
    ) {
        self.model = model
        self.onSave = onSave
        self.onRequestPermission = onRequestPermission
        self.onRequestScreenCapturePermission = onRequestScreenCapturePermission
        self.conversationProfilesView = ConversationProfilesSettingsView(store: model.intelligence)
        self.rewriteHistoryView = RewriteHistorySettingsView(store: model.intelligence)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pole 设置"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 650, height: 600)
        super.init(window: window)
        window.contentView = buildContentView()
        loadModelIntoControls()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        refreshPermissionState()
        loadModelIntoControls()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContentView() -> NSView {
        let root = NSView()
        let title = NSTextField(labelWithString: "Pole")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "你的本地优先沟通增强层")
        subtitle.textColor = .secondaryLabelColor
        let header = verticalStack([title, subtitle], spacing: 3)

        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        tabs.addTabViewItem(tabItem(label: "通用", view: buildGeneralTab()))
        tabs.addTabViewItem(tabItem(label: "沟通智能", view: buildIntelligenceTab()))
        tabs.addTabViewItem(tabItem(label: "优化历史", view: rewriteHistoryView))
        tabs.addTabViewItem(tabItem(label: "聊天对象", view: buildRelationshipsTab()))
        tabs.addTabViewItem(tabItem(label: "隐私", view: buildPrivacyTab()))

        let permissionButton = NSButton(title: "去授权 / 刷新", target: self, action: #selector(permissionClicked))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let footer = horizontalStack(
            [permissionLabel, permissionButton, flexibleSpacer(), saveButton],
            spacing: 10
        )

        let stack = NSStackView(views: [header, tabs, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 510),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private func buildGeneralTab() -> NSView {
        let content = tabContainer()
        let apiLabel = NSTextField(labelWithString: "API Key")
        apiLabel.font = .systemFont(ofSize: 13, weight: .medium)
        apiKeyField.placeholderString = "sk-..."
        apiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let keyButton = NSButton(title: "获取 API Key", target: self, action: #selector(openAPIKeyPage))
        keyButton.bezelStyle = .inline
        modelPicker.addItems(withTitles: ["Qwen 3.7 Plus", "Qwen 3.6 Flash"])
        let modelRow = horizontalStack([
            NSTextField(labelWithString: "模型"), modelPicker, flexibleSpacer(), keyButton
        ], spacing: 10)
        let privacy = secondaryLabel("API Key 只保存在 macOS 钥匙串；当前待处理文本会发送给通义千问。")
        let qwenBox = makeBox(
            title: "通义千问",
            content: verticalStack([apiLabel, apiKeyField, modelRow, privacy], spacing: 10),
            height: 162
        )

        promptTextView.font = .systemFont(ofSize: 12)
        promptTextView.textColor = .textColor
        promptTextView.backgroundColor = .textBackgroundColor
        promptTextView.drawsBackground = true
        promptTextView.frame = NSRect(x: 0, y: 0, width: 600, height: 150)
        promptTextView.isRichText = false
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.autoresizingMask = [.width]
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.textContainer?.widthTracksTextView = true
        let promptScroll = NSScrollView()
        promptScroll.documentView = promptTextView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        intervalSlider.numberOfTickMarks = 16
        intervalSlider.allowsTickMarkValuesOnly = true
        intervalSlider.target = self
        intervalSlider.action = #selector(intervalChanged)
        intervalLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        intervalLabel.alignment = .right
        intervalLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let intervalRow = horizontalStack([
            NSTextField(labelWithString: "两次 Option 最长间隔"), intervalSlider, intervalLabel
        ], spacing: 10)
        let rulesBox = makeBox(
            title: "基础优化规则",
            content: verticalStack([promptScroll, intervalRow], spacing: 12),
            height: 225
        )
        pin(verticalStack([qwenBox, rulesBox], spacing: 16), in: content)
        return content
    }

    private func buildIntelligenceTab() -> NSView {
        let content = tabContainer()
        helperPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        helperPathLabel.lineBreakMode = .byTruncatingMiddle
        helperStatusLabel.font = .systemFont(ofSize: 11)
        helperStatusLabel.textColor = .secondaryLabelColor
        let chooseButton = NSButton(title: "选择 helper…", target: self, action: #selector(chooseHelper))
        let testButton = NSButton(title: "测试连接", target: self, action: #selector(testHelper))
        let removeButton = NSButton(title: "移除", target: self, action: #selector(removeHelper))
        let helperButtons = horizontalStack([chooseButton, testButton, removeButton, flexibleSpacer()], spacing: 8)
        let helperHint = secondaryLabel(
            "Pole 只调用用户提供的只读 JSON helper，不安装组件、不提取密钥，也不修改微信。协议包含 capabilities、sessions 和 history。"
        )
        let helperBox = makeBox(
            title: "外部聊天历史 helper",
            content: verticalStack([helperPathLabel, helperStatusLabel, helperButtons, helperHint], spacing: 9),
            height: 170
        )

        historyCheckbox.target = self
        learningCheckbox.target = self
        let consentHint = secondaryLabel("聊天 helper 原文只在内存中分析；优化历史会加密保存在本机，云端只接收当前待处理文本和不含正文的风格摘要。")
        let consentBox = makeBox(
            title: "本地学习授权",
            content: verticalStack([historyCheckbox, learningCheckbox, consentHint], spacing: 10),
            height: 116
        )

        voiceSummaryLabel.font = .systemFont(ofSize: 12)
        let resetVoice = NSButton(title: "重置声音画像", target: self, action: #selector(resetVoiceProfile))
        let voiceBox = makeBox(
            title: "我的声音",
            content: verticalStack([voiceSummaryLabel, horizontalStack([resetVoice, flexibleSpacer()], spacing: 8)], spacing: 12),
            height: 112
        )
        pinVerticalBoxes([helperBox, consentBox, voiceBox], in: content, spacing: 14)
        return content
    }

    private func buildRelationshipsTab() -> NSView {
        let content = tabContainer()
        pin(conversationProfilesView, in: content, inset: 12)
        return content
    }

    private func buildPrivacyTab() -> NSView {
        let content = tabContainer()
        let screenCaptureButton = NSButton(
            title: "启用 OCR 识别",
            target: self,
            action: #selector(screenCapturePermissionClicked)
        )
        let screenRow = horizontalStack([
            screenCapturePermissionLabel, flexibleSpacer(), screenCaptureButton
        ], spacing: 10)
        let screenHint = secondaryLabel("仅在辅助功能无法读取聊天标题时截取当前窗口顶部，并在本机 OCR。")
        let captureBox = makeBox(
            title: "聊天对象识别",
            content: verticalStack([screenRow, screenHint], spacing: 10),
            height: 104
        )

        let boundary = secondaryLabel(
            "聊天标题、会话 ID、helper 数据、优化历史正文和关系证据不会发送给通义千问。云端只接收当前待润色文本，以及由本地画像生成的不含姓名和历史正文的表达策略。加密数据保存在 Application Support，密钥保存在系统钥匙串。"
        )
        let exportButton = NSButton(title: "导出派生画像…", target: self, action: #selector(exportProfiles))
        let clearButton = NSButton(title: "清除全部智能数据…", target: self, action: #selector(clearIntelligenceData))
        let dataBox = makeBox(
            title: "数据边界",
            content: verticalStack([
                boundary,
                horizontalStack([exportButton, clearButton, flexibleSpacer()], spacing: 8)
            ], spacing: 14),
            height: 150
        )
        let appRules = secondaryLabel(
            "应用身份始终优先：Codex、ChatGPT、邮件、开发工具和文档使用各自规则；只有聊天应用会读取关系画像。右 Option 翻译不读取任何画像。"
        )
        let appBox = makeBox(title: "固定安全规则", content: appRules, height: 100)
        pinVerticalBoxes([captureBox, dataBox, appBox], in: content, spacing: 16)
        return content
    }

    private func tabItem(label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func tabContainer() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 470))
        view.autoresizingMask = [.width, .height]
        return view
    }

    private func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 18) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(lessThanOrEqualTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func pinVerticalBoxes(
        _ boxes: [NSView],
        in parent: NSView,
        inset: CGFloat = 18,
        spacing: CGFloat
    ) {
        var previous: NSView?
        for box in boxes {
            box.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
                box.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
                box.topAnchor.constraint(
                    equalTo: previous?.bottomAnchor ?? parent.topAnchor,
                    constant: previous == nil ? inset : spacing
                )
            ])
            previous = box
        }
        if let previous {
            previous.bottomAnchor.constraint(lessThanOrEqualTo: parent.bottomAnchor, constant: -inset).isActive = true
        }
    }

    private func makeBox(title: String, content: NSView, height: CGFloat) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        let container = NSView()
        box.contentView = container
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return box
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func loadModelIntoControls() {
        apiKeyField.stringValue = model.apiKey
        modelPicker.selectItem(at: model.modelName == "qwen3.6-flash" ? 1 : 0)
        promptTextView.string = model.prompt
        intervalSlider.doubleValue = model.triggerInterval
        historyCheckbox.state = model.historyAnalysisEnabled ? .on : .off
        learningCheckbox.state = model.rewriteLearningEnabled ? .on : .off
        helperPathLabel.stringValue = model.helperPath.isEmpty ? "未配置本地 helper" : model.helperPath
        helperStatusLabel.stringValue = model.helperStatusText
        updateIntervalLabel()
        updateVoiceSummary()
    }

    private func updateVoiceSummary() {
        let voice = model.intelligence.voice
        guard voice.sampleCount > 0 else {
            voiceSummaryLabel.stringValue = "尚未建立用户声音画像"
            return
        }
        voiceSummaryLabel.stringValue = String(
            format: "已从 %d 条本地样本学习 · 直接度 %.0f%% · 正式度 %.0f%% · 平均句长 %.0f 字",
            voice.sampleCount,
            voice.metrics.directness * 100,
            voice.metrics.formality * 100,
            voice.metrics.averageSentenceLength
        )
    }

    func refreshPermissionState() {
        if AccessibilityPermission.isTrusted {
            permissionLabel.stringValue = "● 辅助功能权限已授予"
            permissionLabel.textColor = .systemGreen
        } else {
            permissionLabel.stringValue = "● 需要辅助功能权限"
            permissionLabel.textColor = .systemOrange
        }
        if ScreenCapturePermission.isGranted {
            screenCapturePermissionLabel.stringValue = "● OCR 屏幕录制权限已授予"
            screenCapturePermissionLabel.textColor = .systemGreen
        } else {
            screenCapturePermissionLabel.stringValue = "● OCR 未授权（仍可读取窗口标题）"
            screenCapturePermissionLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func intervalChanged() { updateIntervalLabel() }

    private func updateIntervalLabel() {
        intervalLabel.stringValue = String(format: "%.1f 秒", intervalSlider.doubleValue)
    }

    @objc private func openAPIKeyPage() {
        guard let url = URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func permissionClicked() {
        AccessibilityPermission.isTrusted ? refreshPermissionState() : onRequestPermission()
    }

    @objc private func screenCapturePermissionClicked() {
        onRequestScreenCapturePermission()
    }

    @objc private func chooseHelper() {
        let panel = NSOpenPanel()
        panel.title = "选择只读聊天历史 helper"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setHelperURL(url)
        helperPathLabel.stringValue = model.helperPath.isEmpty ? "未配置本地 helper" : model.helperPath
        helperStatusLabel.stringValue = model.helperPath.isEmpty
            ? model.helperStatusText
            : "待检测；Pole 不会执行安装或提权"
    }

    @objc private func removeHelper() {
        model.setHelperURL(nil)
        helperPathLabel.stringValue = "未配置本地 helper"
        helperStatusLabel.stringValue = ""
        historyCheckbox.state = .off
        learningCheckbox.state = .off
    }

    @objc private func testHelper() {
        guard let url = model.helperURL else {
            helperStatusLabel.stringValue = "请先选择 helper"
            return
        }
        helperStatusLabel.stringValue = "正在检测…"
        Task { [weak self] in
            do {
                let capabilities = try await ExternalHelperProvider(executableURL: url).capabilities()
                await MainActor.run {
                    self?.model.helperStatusText = "已连接 · \(capabilities.provider) · 协议 v\(capabilities.protocolVersion)"
                    self?.helperStatusLabel.stringValue = self?.model.helperStatusText ?? "已连接"
                }
            } catch {
                await MainActor.run {
                    self?.model.helperStatusText = "检测失败"
                    self?.helperStatusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func resetVoiceProfile() {
        model.intelligence.resetVoice()
        updateVoiceSummary()
    }

    @objc private func exportProfiles() {
        guard let data = try? model.intelligence.exportDerivedProfileData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pole-派生画像.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    @objc private func clearIntelligenceData() {
        let alert = NSAlert()
        alert.messageText = "清除全部智能数据？"
        alert.informativeText = "将删除关系画像、声音画像、优化历史和待学习样本；API Key 与基础设置不受影响。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.intelligence.clearAll()
        updateVoiceSummary()
    }

    @objc private func saveClicked() {
        model.apiKey = apiKeyField.stringValue
        model.modelName = modelPicker.indexOfSelectedItem == 1 ? "qwen3.6-flash" : "qwen3.7-plus"
        model.prompt = promptTextView.string
        model.triggerInterval = intervalSlider.doubleValue
        model.historyAnalysisEnabled = historyCheckbox.state == .on
        model.rewriteLearningEnabled = learningCheckbox.state == .on
        onSave()
    }
}

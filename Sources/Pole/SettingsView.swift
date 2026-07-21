import AppKit

final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private let onSave: () -> Void
    private let onRequestPermission: () -> Void

    private let apiKeyField = NSSecureTextField()
    private let modelPicker = NSPopUpButton()
    private let promptTextView = NSTextView()
    private let intervalSlider = NSSlider(value: 1.2, minValue: 0.5, maxValue: 2.0, target: nil, action: nil)
    private let intervalLabel = NSTextField(labelWithString: "1.2 秒")
    private let permissionLabel = NSTextField(labelWithString: "")

    init(model: AppModel, onSave: @escaping () -> Void, onRequestPermission: @escaping () -> Void) {
        self.model = model
        self.onSave = onSave
        self.onRequestPermission = onRequestPermission

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pole 设置"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 520)
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
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])

        let title = NSTextField(labelWithString: "Pole")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "左 Option 连按两次润色，右 Option 连按两次翻译。")
        subtitle.textColor = .secondaryLabelColor
        let header = verticalStack([title, subtitle], spacing: 4)
        stack.addArrangedSubview(header)

        let apiLabel = NSTextField(labelWithString: "API Key")
        apiLabel.font = .systemFont(ofSize: 13, weight: .medium)
        apiKeyField.placeholderString = "sk-..."
        apiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let modelLabel = NSTextField(labelWithString: "模型")
        modelPicker.addItems(withTitles: ["Qwen 3.7 Plus", "Qwen 3.6 Flash"])
        modelPicker.setAccessibilityLabel("通义千问模型")

        let keyButton = NSButton(title: "获取 API Key", target: self, action: #selector(openAPIKeyPage))
        keyButton.bezelStyle = .inline
        let modelRow = horizontalStack([modelLabel, modelPicker, flexibleSpacer(), keyButton], spacing: 10)

        let privacy = NSTextField(
            wrappingLabelWithString: "API Key 只保存在 macOS 钥匙串中。触发润色或翻译时，当前段落会发送给通义千问。"
        )
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor

        let qwenStack = verticalStack([apiLabel, apiKeyField, modelRow, privacy], spacing: 10)
        let qwenBox = makeBox(title: "通义千问", content: qwenStack, height: 160)
        stack.addArrangedSubview(qwenBox)

        promptTextView.font = .systemFont(ofSize: 12)
        promptTextView.isRichText = false
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.textContainer?.widthTracksTextView = true
        let promptScroll = NSScrollView()
        promptScroll.documentView = promptTextView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.heightAnchor.constraint(equalToConstant: 105).isActive = true

        intervalSlider.numberOfTickMarks = 16
        intervalSlider.allowsTickMarkValuesOnly = true
        intervalSlider.target = self
        intervalSlider.action = #selector(intervalChanged)
        intervalLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        intervalLabel.alignment = .right
        intervalLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let intervalTitle = NSTextField(labelWithString: "两次 Option 最长间隔")
        let intervalRow = horizontalStack(
            [intervalTitle, intervalSlider, intervalLabel],
            spacing: 10
        )

        let promptStack = verticalStack([promptScroll, intervalRow], spacing: 12)
        let promptBox = makeBox(title: "优化规则", content: promptStack, height: 185)
        stack.addArrangedSubview(promptBox)

        let permissionButton = NSButton(title: "去授权 / 刷新", target: self, action: #selector(permissionClicked))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let footer = horizontalStack(
            [permissionLabel, permissionButton, flexibleSpacer(), saveButton],
            spacing: 10
        )
        stack.addArrangedSubview(footer)

        [header, qwenBox, promptBox, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return root
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
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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

    private func loadModelIntoControls() {
        apiKeyField.stringValue = model.apiKey
        modelPicker.selectItem(at: model.modelName == "qwen3.6-flash" ? 1 : 0)
        promptTextView.string = model.prompt
        intervalSlider.doubleValue = model.triggerInterval
        updateIntervalLabel()
    }

    func refreshPermissionState() {
        if AccessibilityPermission.isTrusted {
            permissionLabel.stringValue = "● 辅助功能权限已授予"
            permissionLabel.textColor = .systemGreen
        } else {
            permissionLabel.stringValue = "● 需要辅助功能权限"
            permissionLabel.textColor = .systemOrange
        }
    }

    @objc private func intervalChanged() {
        updateIntervalLabel()
    }

    private func updateIntervalLabel() {
        intervalLabel.stringValue = String(format: "%.1f 秒", intervalSlider.doubleValue)
    }

    @objc private func openAPIKeyPage() {
        guard let url = URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func permissionClicked() {
        if AccessibilityPermission.isTrusted {
            refreshPermissionState()
        } else {
            onRequestPermission()
        }
    }

    @objc private func saveClicked() {
        model.apiKey = apiKeyField.stringValue
        model.modelName = modelPicker.indexOfSelectedItem == 1
            ? "qwen3.6-flash"
            : "qwen3.7-plus"
        model.prompt = promptTextView.string
        model.triggerInterval = intervalSlider.doubleValue
        onSave()
    }
}

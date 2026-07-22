import AppKit

private final class ConversationInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ConversationProfilePanel: NSObject {
    enum Decision {
        case save(role: ConversationRole, instruction: String)
        case useGeneric
        case cancel
    }

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let roleControl = NSSegmentedControl(
        labels: ["上级", "客户", "同事", "朋友", "自定义"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let instructionTextView = NSTextView()
    private var panel: NSPanel?
    private var completion: ((Decision) -> Void)?
    private var generatedInstruction = ConversationRole.manager.defaultInstruction

    func show(
        conversationTitle: String,
        at accessibilityScreenRect: CGRect?,
        completion: @escaping (Decision) -> Void
    ) {
        dismiss(notify: false)
        self.completion = completion
        titleLabel.stringValue = "当前会话：\(conversationTitle)"
        roleControl.selectedSegment = 0
        generatedInstruction = ConversationRole.manager.defaultInstruction
        instructionTextView.string = generatedInstruction

        let content = buildContentView()
        let panel = ConversationInputPanel(
            contentRect: content.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.setFrameOrigin(origin(for: accessibilityScreenRect, size: content.bounds.size))

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(instructionTextView)
    }

    func dismiss(notify: Bool = false) {
        let panel = self.panel
        self.panel = nil
        panel?.orderOut(nil)
        guard notify else { return }
        let completion = self.completion
        self.completion = nil
        completion?(.cancel)
    }

    private func buildContentView() -> NSView {
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 410, height: 294))
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        let privacyLabel = NSTextField(
            wrappingLabelWithString: "名称仅保存在本机；发送给模型的只有下面这条表达规则。"
        )
        privacyLabel.font = .systemFont(ofSize: 11)
        privacyLabel.textColor = .secondaryLabelColor

        let roleLabel = NSTextField(labelWithString: "沟通对象")
        roleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        roleControl.target = self
        roleControl.action = #selector(roleChanged)
        roleControl.selectedSegment = 0
        roleControl.setWidth(55, forSegment: 0)
        roleControl.setWidth(55, forSegment: 1)
        roleControl.setWidth(55, forSegment: 2)
        roleControl.setWidth(58, forSegment: 3)
        roleControl.setWidth(62, forSegment: 4)

        let instructionLabel = NSTextField(labelWithString: "个人表达规则")
        instructionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        instructionTextView.font = .systemFont(ofSize: 12)
        instructionTextView.isEditable = true
        instructionTextView.isSelectable = true
        instructionTextView.isRichText = false
        instructionTextView.isVerticallyResizable = true
        instructionTextView.isHorizontallyResizable = false
        instructionTextView.backgroundColor = .textBackgroundColor
        instructionTextView.textColor = .textColor
        instructionTextView.insertionPointColor = .controlAccentColor
        instructionTextView.textContainerInset = NSSize(width: 6, height: 6)
        instructionTextView.isAutomaticQuoteSubstitutionEnabled = false
        instructionTextView.isAutomaticDashSubstitutionEnabled = false
        instructionTextView.textContainer?.widthTracksTextView = true
        let instructionScroll = NSScrollView()
        instructionScroll.documentView = instructionTextView
        instructionScroll.hasVerticalScroller = true
        instructionScroll.borderType = .bezelBorder
        instructionScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true

        let genericButton = NSButton(title: "本次按通用润色", target: self, action: #selector(useGeneric))
        genericButton.bezelStyle = .inline
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        let saveButton = NSButton(title: "保存并润色", target: self, action: #selector(saveAndPolish))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [genericButton, flexibleSpacer(), cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [
            titleLabel,
            privacyLabel,
            roleLabel,
            roleControl,
            instructionLabel,
            instructionScroll,
            footer
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -14),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructionScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return visualEffect
    }

    @objc private func roleChanged() {
        let role = selectedRole
        let currentInstruction = instructionTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentInstruction.isEmpty || currentInstruction == generatedInstruction else { return }
        generatedInstruction = role.defaultInstruction
        instructionTextView.string = generatedInstruction
    }

    @objc private func saveAndPolish() {
        let instruction = instructionTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(.save(
            role: selectedRole,
            instruction: instruction.isEmpty ? selectedRole.defaultInstruction : instruction
        ))
    }

    @objc private func useGeneric() {
        finish(.useGeneric)
    }

    @objc private func cancel() {
        finish(.cancel)
    }

    private var selectedRole: ConversationRole {
        let index = max(roleControl.selectedSegment, 0)
        return ConversationRole.allCases[min(index, ConversationRole.allCases.count - 1)]
    }

    private func finish(_ decision: Decision) {
        let panel = self.panel
        self.panel = nil
        panel?.orderOut(nil)
        let completion = self.completion
        self.completion = nil
        completion?(decision)
    }

    private func origin(for accessibilityScreenRect: CGRect?, size: NSSize) -> NSPoint {
        let proposed: NSPoint
        if let accessibilityScreenRect,
           let screen = NSScreen.screens.first {
            let caretRect = NSRect(
                x: accessibilityScreenRect.minX,
                y: screen.frame.maxY - accessibilityScreenRect.maxY,
                width: accessibilityScreenRect.width,
                height: accessibilityScreenRect.height
            )
            proposed = NSPoint(x: caretRect.minX, y: caretRect.maxY + 10)
        } else {
            let mouse = NSEvent.mouseLocation
            proposed = NSPoint(x: mouse.x + 8, y: mouse.y + 10)
        }

        let screen = NSScreen.screens.first { $0.frame.contains(proposed) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return proposed }
        return NSPoint(
            x: min(max(proposed.x, visibleFrame.minX + 6), visibleFrame.maxX - size.width - 6),
            y: min(max(proposed.y, visibleFrame.minY + 6), visibleFrame.maxY - size.height - 6)
        )
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    deinit {
        dismiss(notify: false)
    }
}

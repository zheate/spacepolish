import AppKit
import Combine

final class ConversationProfilesSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: CommunicationIntelligenceStore
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(
        wrappingLabelWithString: "还没有已绑定的聊天对象。第一次在可识别的聊天窗口润色时，Pole 会提示你创建个人规则。"
    )
    private let selectedTitleLabel = NSTextField(labelWithString: "未选择会话")
    private let confidenceLabel = NSTextField(labelWithString: "")
    private let probabilityLabel = NSTextField(wrappingLabelWithString: "")
    private let evidenceLabel = NSTextField(wrappingLabelWithString: "")
    private let dimensionsLabel = NSTextField(wrappingLabelWithString: "")
    private let rolePicker = NSPopUpButton()
    private let instructionTextView = NSTextView()
    private let saveButton = NSButton(title: "保存对象规则", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除对象", target: nil, action: nil)
    private let confirmChangeButton = NSButton(title: "确认关系变化", target: nil, action: nil)
    private var selectedProfileID: UUID?
    private var profileSubscription: AnyCancellable?

    init(store: CommunicationIntelligenceStore) {
        self.store = store
        super.init(frame: .zero)
        buildContent()
        profileSubscription = store.$relationships
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadProfiles() }
        reloadProfiles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        let description = NSTextField(
            wrappingLabelWithString: "会话名称和个人规则仅保存在本机。发送给模型时不会包含会话名称。"
        )
        description.font = .systemFont(ofSize: 11)
        description.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversationTitle"))
        column.title = "已识别会话"
        column.width = 250
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.heightAnchor.constraint(equalToConstant: 82).isActive = true

        selectedTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        selectedTitleLabel.lineBreakMode = .byTruncatingTail
        confidenceLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        confidenceLabel.textColor = .secondaryLabelColor
        probabilityLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        probabilityLabel.textColor = .secondaryLabelColor
        evidenceLabel.font = .systemFont(ofSize: 11)
        evidenceLabel.textColor = .secondaryLabelColor
        evidenceLabel.maximumNumberOfLines = 2
        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dimensionsLabel.textColor = .secondaryLabelColor
        dimensionsLabel.maximumNumberOfLines = 2

        rolePicker.addItems(withTitles: ConversationRole.allCases.map(\.displayName))
        let roleRow = NSStackView(views: [
            NSTextField(labelWithString: "对象类型"),
            rolePicker,
            flexibleSpacer()
        ])
        roleRow.orientation = .horizontal
        roleRow.alignment = .centerY
        roleRow.spacing = 10

        let instructionLabel = NSTextField(labelWithString: "个人表达规则")
        instructionTextView.font = .systemFont(ofSize: 12)
        instructionTextView.textColor = .textColor
        instructionTextView.backgroundColor = .textBackgroundColor
        instructionTextView.drawsBackground = true
        instructionTextView.frame = NSRect(x: 0, y: 0, width: 600, height: 62)
        instructionTextView.isRichText = false
        instructionTextView.isVerticallyResizable = true
        instructionTextView.isHorizontallyResizable = false
        instructionTextView.autoresizingMask = [.width]
        instructionTextView.isAutomaticQuoteSubstitutionEnabled = false
        instructionTextView.isAutomaticDashSubstitutionEnabled = false
        instructionTextView.textContainer?.widthTracksTextView = true
        let instructionScroll = NSScrollView()
        instructionScroll.documentView = instructionTextView
        instructionScroll.hasVerticalScroller = true
        instructionScroll.borderType = .bezelBorder
        instructionScroll.heightAnchor.constraint(equalToConstant: 62).isActive = true

        saveButton.target = self
        saveButton.action = #selector(saveSelectedProfile)
        saveButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedProfile)
        deleteButton.bezelStyle = .rounded
        confirmChangeButton.target = self
        confirmChangeButton.action = #selector(confirmPendingChange)
        confirmChangeButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [confirmChangeButton, flexibleSpacer(), deleteButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [
            description,
            emptyLabel,
            tableScroll,
            selectedTitleLabel,
            confidenceLabel,
            probabilityLabel,
            evidenceLabel,
            dimensionsLabel,
            roleRow,
            instructionLabel,
            instructionScroll,
            buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            selectedTitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            confidenceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            probabilityLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            evidenceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dimensionsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            roleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructionScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func reloadProfiles() {
        let previousID = selectedProfileID
        tableView.reloadData()
        if let previousID,
           let index = store.relationships.firstIndex(where: { $0.id == previousID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            loadProfile(store.relationships[index])
        } else if let first = store.relationships.first {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadProfile(first)
        } else {
            selectedProfileID = nil
            selectedTitleLabel.stringValue = "未选择会话"
            confidenceLabel.stringValue = ""
            probabilityLabel.stringValue = ""
            evidenceLabel.stringValue = ""
            dimensionsLabel.stringValue = ""
            instructionTextView.string = ""
            setEditorEnabled(false)
        }
        emptyLabel.isHidden = !store.relationships.isEmpty
        tableView.enclosingScrollView?.isHidden = store.relationships.isEmpty
    }

    private func loadProfile(_ profile: RelationshipProfile) {
        selectedProfileID = profile.id
        let applicationName = ApplicationContextClassifier.context(
            bundleIdentifier: profile.applicationIdentifier
        ).displayName
        selectedTitleLabel.stringValue = "\(applicationName) · \(profile.conversationTitle)"
        confidenceLabel.stringValue = "关系置信度 \(Int((profile.confidence * 100).rounded()))% · \(profile.role.displayName)"
        probabilityLabel.stringValue = String(
            format: "角色概率  上级 %.0f%% · 客户 %.0f%% · 同事 %.0f%% · 朋友/家人 %.0f%% · 自定义 %.0f%%",
            profile.probabilities.manager * 100,
            profile.probabilities.customer * 100,
            profile.probabilities.colleague * 100,
            profile.probabilities.friendOrFamily * 100,
            profile.probabilities.custom * 100
        )
        evidenceLabel.stringValue = profile.evidence.joined(separator: "；")
        dimensionsLabel.stringValue = String(
            format: "关系参数  权力距离 %.0f%% · 熟悉度 %.0f%% · 正式度 %.0f%% · 直接度 %.0f%% · 详细度 %.0f%%",
            profile.dimensions.powerDistance * 100,
            profile.dimensions.familiarity * 100,
            profile.dimensions.formality * 100,
            profile.dimensions.directness * 100,
            profile.dimensions.detail * 100
        )
        rolePicker.selectItem(at: ConversationRole.allCases.firstIndex(of: profile.role) ?? 0)
        instructionTextView.string = profile.customInstruction
        if let pending = profile.pendingChange, pending.observationCount >= 2 {
            confirmChangeButton.title = "确认改为\(pending.proposedRole.displayName)"
            confirmChangeButton.isHidden = false
        } else {
            confirmChangeButton.isHidden = true
        }
        setEditorEnabled(true)
    }

    private func setEditorEnabled(_ enabled: Bool) {
        rolePicker.isEnabled = enabled
        instructionTextView.isEditable = enabled
        instructionTextView.isSelectable = enabled
        saveButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
        confirmChangeButton.isEnabled = enabled
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.relationships.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard store.relationships.indices.contains(row) else { return nil }
        let profile = store.relationships[row]
        let identifier = NSUserInterfaceItemIdentifier("conversationProfileCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier

        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = label
        }
        let applicationName = ApplicationContextClassifier.context(
            bundleIdentifier: profile.applicationIdentifier
        ).displayName
        label.stringValue = "\(applicationName) · \(profile.conversationTitle) · \(profile.role.displayName) · \(Int((profile.confidence * 100).rounded()))%"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard store.relationships.indices.contains(row) else { return }
        loadProfile(store.relationships[row])
    }

    @objc private func saveSelectedProfile() {
        guard let selectedProfileID else { return }
        let index = max(rolePicker.indexOfSelectedItem, 0)
        let role = ConversationRole.allCases[min(index, ConversationRole.allCases.count - 1)]
        store.update(
            id: selectedProfileID,
            role: role,
            customInstruction: instructionTextView.string
        )
    }

    @objc private func deleteSelectedProfile() {
        guard let selectedProfileID else { return }
        store.delete(id: selectedProfileID)
    }

    @objc private func confirmPendingChange() {
        guard let selectedProfileID else { return }
        store.confirmPendingChange(id: selectedProfileID)
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }
}

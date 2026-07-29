import AppKit
import Combine

final class RewriteHistorySettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: CommunicationIntelligenceStore
    private let tableView = NSTableView()
    private let sourceTextView = NSTextView()
    private let rewrittenTextView = NSTextView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton(title: "删除所选", target: nil, action: nil)
    private var cancellable: AnyCancellable?

    init(store: CommunicationIntelligenceStore) {
        self.store = store
        super.init(frame: .zero)
        buildView()
        cancellable = store.$rewriteHistory.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reloadData() }
        }
        reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildView() {
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "时间"
        dateColumn.width = 116
        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = "原文"
        sourceColumn.width = 205
        let resultColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        resultColumn.title = "优化结果"
        resultColumn.width = 205
        let feedbackColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("feedback"))
        feedbackColumn.title = "反馈"
        feedbackColumn.width = 72
        [dateColumn, sourceColumn, resultColumn, feedbackColumn].forEach(tableView.addTableColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 28
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        configureDetailTextView(sourceTextView)
        configureDetailTextView(rewrittenTextView)
        let sourceBox = detailBox(title: "原文", textView: sourceTextView)
        let resultBox = detailBox(title: "优化结果", textView: rewrittenTextView)
        let details = NSStackView(views: [sourceBox, resultBox])
        details.orientation = .horizontal
        details.distribution = .fillEqually
        details.spacing = 12
        sourceBox.heightAnchor.constraint(equalTo: details.heightAnchor).isActive = true
        resultBox.heightAnchor.constraint(equalTo: details.heightAnchor).isActive = true

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: 11)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        let clearButton = NSButton(title: "清空历史…", target: self, action: #selector(clearHistory))
        let footer = NSStackView(views: [summaryLabel, flexibleSpacer(), deleteButton, clearButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [tableScroll, details, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.heightAnchor.constraint(equalToConstant: 220),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.heightAnchor.constraint(equalToConstant: 190),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func configureDetailTextView(_ textView: NSTextView) {
        textView.frame = NSRect(x: 0, y: 0, width: 280, height: 160)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .textBackgroundColor
    }

    private func detailBox(title: String, textView: NSTextView) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        let container = NSView()
        box.contentView = container
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return box
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func reloadData() {
        tableView.reloadData()
        summaryLabel.stringValue = "本机加密保存 \(store.rewriteHistory.count) 条 · 最多 200 条 / 180 天"
        if store.rewriteHistory.isEmpty {
            tableView.deselectAll(nil)
            sourceTextView.string = "尚无优化历史"
            rewrittenTextView.string = "开启“本地记录优化历史并学习我的表达”后，成功润色会显示在这里。"
            deleteButton.isEnabled = false
        } else if !store.rewriteHistory.indices.contains(tableView.selectedRow) {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            updateDetails()
        } else {
            updateDetails()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.rewriteHistory.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard store.rewriteHistory.indices.contains(row), let tableColumn else { return nil }
        let entry = store.rewriteHistory[row]
        let cell = NSTextField(labelWithString: value(for: tableColumn.identifier.rawValue, entry: entry))
        cell.lineBreakMode = .byTruncatingTail
        cell.maximumNumberOfLines = 1
        cell.font = tableColumn.identifier.rawValue == "date"
            ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 11)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetails()
    }

    private func value(for column: String, entry: RewriteHistoryEntry) -> String {
        switch column {
        case "date":
            return Self.dateFormatter.string(from: entry.createdAt)
        case "source":
            return entry.sourceText.replacingOccurrences(of: "\n", with: " ↵ ")
        case "result":
            return entry.rewrittenText.replacingOccurrences(of: "\n", with: " ↵ ")
        case "feedback":
            return entry.feedback?.displayName ?? (entry.changed ? "已改写" : "未修改")
        default:
            return ""
        }
    }

    private func updateDetails() {
        let row = tableView.selectedRow
        guard store.rewriteHistory.indices.contains(row) else {
            deleteButton.isEnabled = false
            return
        }
        let entry = store.rewriteHistory[row]
        sourceTextView.string = entry.sourceText
        rewrittenTextView.string = entry.rewrittenText
        deleteButton.isEnabled = true
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard store.rewriteHistory.indices.contains(row) else { return }
        store.deleteRewriteHistory(id: store.rewriteHistory[row].id)
    }

    @objc private func clearHistory() {
        guard !store.rewriteHistory.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清空全部优化历史？"
        alert.informativeText = "历史原文和优化结果将从本机加密库删除。已形成的声音画像不会自动重置。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearRewriteHistory()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

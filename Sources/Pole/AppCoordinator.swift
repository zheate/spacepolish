import AppKit

final class AppCoordinator: NSObject, NSMenuDelegate {
    private enum RewriteAction {
        case polish
        case translate

        var promptDescription: String {
            switch self {
            case .polish:
                return "正在优化…"
            case .translate:
                return "正在翻译…"
            }
        }
    }

    private struct PendingCompletion {
        let context: CapturedTextContext
        let cursorUTF16: Int
        let outcome: OptimizationOutcome
        let action: RewriteAction
    }

    private struct RecentRewriteFeedbackContext {
        let relationshipID: UUID?
        let createdAt: Date
    }

    let model = AppModel()

    private let client = QwenClient()
    private let textService = AccessibilityTextService()
    private let conversationResolver = ConversationResolver()
    private let monitor = DoubleOptionMonitor()
    private let hud = StatusHUD()
    private let inputProgressIndicator = InputProgressIndicator()
    private let conversationProfilePanel = ConversationProfilePanel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var settingsController: SettingsWindowController?
    private var isMonitorStarted = false
    private var pendingCompletion: PendingCompletion?
    private var recentRewriteFeedbackContext: RecentRewriteFeedbackContext?

    override init() {
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "wand.and.stars",
            accessibilityDescription: "Pole"
        )
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.isEnabled = { [weak self] in
            guard let self else { return false }
            return self.model.isEnabled && !self.model.isProcessing
        }
        monitor.maximumInterval = { [weak self] in
            self?.model.triggerInterval ?? 1.2
        }
        monitor.onTrigger = { [weak self] side in
            self?.handleTrigger(side == .right ? .translate : .polish)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func start() {
        guard AccessibilityPermission.isTrusted else {
            model.statusText = "等待辅助功能授权"
            AccessibilityPermission.request()
            openSettings()
            return
        }
        startMonitor()
        ConversationResolver.prewarmTextRecognition()
        if !model.hasAPIKey {
            model.statusText = "请设置通义千问 API Key"
            openSettings()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: model.isEnabled ? "暂停 Option 快捷键" : "启用 Option 快捷键",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        if let feedbackContext = recentRewriteFeedbackContext,
           Date().timeIntervalSince(feedbackContext.createdAt) <= 86_400 {
            let feedbackItem = NSMenuItem(title: "评价最近一次优化", action: nil, keyEquivalent: "")
            let feedbackMenu = NSMenu()
            for (index, feedback) in RewriteFeedback.allCases.enumerated() {
                let item = NSMenuItem(
                    title: feedback.displayName,
                    action: #selector(applyRewriteFeedback(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                feedbackMenu.addItem(item)
            }
            feedbackItem.submenu = feedbackMenu
            menu.addItem(feedbackItem)
        }

        if !AccessibilityPermission.isTrusted {
            let permission = NSMenuItem(
                title: "授予辅助功能权限…",
                action: #selector(requestPermission),
                keyEquivalent: ""
            )
            permission.target = self
            menu.addItem(permission)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Pole", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        model.isEnabled.toggle()
        try? model.save()
        model.statusText = model.isEnabled ? readyStatusText : "已暂停"
    }

    @objc private func applyRewriteFeedback(_ sender: NSMenuItem) {
        guard RewriteFeedback.allCases.indices.contains(sender.tag),
              let context = recentRewriteFeedbackContext else { return }
        model.intelligence.applyFeedback(
            RewriteFeedback.allCases[sender.tag],
            relationshipID: context.relationshipID
        )
        model.statusText = "反馈已在本机学习"
    }

    @objc func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                model: model,
                onSave: { [weak self] in self?.saveSettings() },
                onRequestPermission: { [weak self] in self?.requestPermission() },
                onRequestScreenCapturePermission: { [weak self] in
                    self?.requestScreenCapturePermission()
                }
            )
        }
        settingsController?.present()
    }

    @objc private func requestPermission() {
        AccessibilityPermission.request()
        AccessibilityPermission.openSystemSettings()
        model.statusText = "授权后请切回 Pole"
    }

    private func requestScreenCapturePermission() {
        ScreenCapturePermission.request()
        if !ScreenCapturePermission.isGranted {
            ScreenCapturePermission.openSystemSettings()
        }
        settingsController?.refreshPermissionState()
    }

    @objc private func applicationDidBecomeActive() {
        settingsController?.refreshPermissionState()
        guard AccessibilityPermission.isTrusted, !isMonitorStarted else { return }
        startMonitor()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func saveSettings() {
        do {
            try model.save()
            model.statusText = "设置已保存"
            hud.show("设置已保存")
            if AccessibilityPermission.isTrusted {
                startMonitor()
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func startMonitor() {
        guard !isMonitorStarted else { return }
        do {
            try monitor.start()
            isMonitorStarted = true
            model.statusText = model.isEnabled ? readyStatusText : "已暂停"
        } catch {
            model.statusText = "无法监听键盘"
            showError(error.localizedDescription)
        }
    }

    private var readyStatusText: String {
        "左 Option 润色 · 右 Option 翻译"
    }

    private func handleTrigger(_ action: RewriteAction) {
        guard model.hasAPIKey else {
            model.statusText = model.isEnabled ? readyStatusText : "已暂停"
            return
        }
        guard !model.isProcessing else { return }

        let context: CapturedTextContext
        do {
            context = try textService.captureTargetText()
        } catch {
            model.statusText = model.isEnabled ? readyStatusText : "已暂停"
            return
        }

        if action == .polish {
            handlePolishTrigger(context: context)
        } else {
            beginRewrite(
                context: context,
                action: .translate,
                prompt: TranslationPolicy.prompt,
                conversationSnapshot: nil,
                communicationContext: nil
            )
        }
    }

    private func handlePolishTrigger(context: CapturedTextContext) {
        let snapshot = conversationResolver.resolveCurrentConversation()
        if let snapshot,
           !snapshot.applicationContext.supportsConversationProfiles {
            beginPolish(context: context, snapshot: snapshot, relationship: nil)
            return
        }

        guard let snapshot else {
            beginPolish(context: context, snapshot: nil, relationship: nil)
            return
        }

        let existing = model.intelligence.relationship(for: snapshot)
        let needsRefresh = existing?.lastAnalyzedAt.map {
            Date().timeIntervalSince($0) >= 86_400
        } ?? true
        if model.historyAnalysisEnabled,
           needsRefresh,
           model.helperURL != nil,
           snapshot.normalizedTitle != nil {
            prepareHistoryContext(context: context, snapshot: snapshot, fallback: existing)
            return
        }
        if let existing {
            beginPolish(context: context, snapshot: snapshot, relationship: existing)
            return
        }
        if let inferred = model.intelligence.createInferredRelationship(for: snapshot) {
            beginPolish(context: context, snapshot: snapshot, relationship: inferred)
            return
        }
        requestRelationshipOrUseGeneric(context: context, snapshot: snapshot)
    }

    private func prepareHistoryContext(
        context: CapturedTextContext,
        snapshot: ConversationSnapshot,
        fallback: RelationshipProfile?
    ) {
        guard let helperURL = model.helperURL else {
            beginPolish(context: context, snapshot: snapshot, relationship: fallback)
            return
        }
        model.isProcessing = true
        model.statusText = "正在理解当前会话…"
        inputProgressIndicator.show(
            at: textService.insertionPointScreenRect(for: context),
            operation: .optimization
        )
        let provider = ExternalHelperProvider(executableURL: helperURL)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await provider.capabilities()
                let session = try await provider.resolveSession(for: snapshot)
                let messages = try await provider.history(
                    conversationID: session.id,
                    limit: 200,
                    days: 30
                )
                let analysis = RelationshipAnalyzer.analyze(
                    title: snapshot.title,
                    messages: messages
                )
                try await MainActor.run {
                    guard self.conversationResolver.matchesCurrentConversation(snapshot) else {
                        throw ConversationContextError.changed
                    }
                    guard self.textService.isCurrent(context) else {
                        throw TextEditingError.textChangedWhileWaiting
                    }
                    self.model.helperStatusText = "已连接 · \(session.type)"
                    let resolved = self.model.intelligence.applyAnalysis(
                        analysis,
                        snapshot: snapshot,
                        conversationID: session.id,
                        messages: messages
                    ) ?? fallback
                    if let resolved {
                        self.beginPolish(
                            context: context,
                            snapshot: snapshot,
                            relationship: resolved,
                            progressAlreadyShown: true
                        )
                    } else {
                        self.inputProgressIndicator.fail()
                        self.model.isProcessing = false
                        self.requestRelationshipOrUseGeneric(context: context, snapshot: snapshot)
                    }
                }
            } catch {
                await MainActor.run {
                    if error is ConversationContextError {
                        self.inputProgressIndicator.fail()
                        self.cancelForChangedConversation()
                        return
                    }
                    if error as? TextEditingError == .textChangedWhileWaiting {
                        self.inputProgressIndicator.fail()
                        self.cancelForChangedText()
                        return
                    }
                    self.model.helperStatusText = "不可用，已降级"
                    if let fallback {
                        self.beginPolish(
                            context: context,
                            snapshot: snapshot,
                            relationship: fallback,
                            progressAlreadyShown: true
                        )
                    } else if let inferred = self.model.intelligence.createInferredRelationship(for: snapshot) {
                        self.beginPolish(
                            context: context,
                            snapshot: snapshot,
                            relationship: inferred,
                            progressAlreadyShown: true
                        )
                    } else {
                        self.inputProgressIndicator.fail()
                        self.model.isProcessing = false
                        self.requestRelationshipOrUseGeneric(context: context, snapshot: snapshot)
                    }
                }
            }
        }
    }

    private func requestRelationshipOrUseGeneric(
        context: CapturedTextContext,
        snapshot: ConversationSnapshot
    ) {
        if snapshot.canCreateProfile, let title = snapshot.title {
            showConversationProfilePanel(for: snapshot, title: title, context: context)
        } else {
            beginPolish(context: context, snapshot: snapshot, relationship: nil)
        }
    }

    private func beginPolish(
        context: CapturedTextContext,
        snapshot: ConversationSnapshot?,
        relationship: RelationshipProfile?,
        progressAlreadyShown: Bool = false
    ) {
        let voiceMetrics = model.intelligence.voice.metrics(for: relationship?.id)
        let intent = CommunicationIntentAnalyzer.infer(from: context.sourceText)
        let policy = CommunicationPolicy(
            intent: intent,
            relationshipRole: relationship?.role,
            relationshipConfidence: relationship?.confidence ?? 0,
            dimensions: relationship?.dimensions,
            voice: voiceMetrics,
            customInstruction: relationship?.anonymizedInstruction(),
            messageExpansionRatio: model.intelligence.safety.preferredExpansionRatio
        )
        let applicationContext = snapshot?.applicationContext
            ?? ApplicationContextClassifier.context(bundleIdentifier: "unknown")
        let communicationContext = CommunicationContext(
            applicationContext: applicationContext,
            conversationSnapshot: snapshot,
            relationship: relationship,
            intent: intent,
            voice: model.intelligence.voice,
            policy: policy,
            dataConfidence: relationship?.confidence ?? 0
        )
        beginRewrite(
            context: context,
            action: .polish,
            prompt: polishPrompt(
                for: snapshot,
                conversationInstruction: policy.modelInstruction
            ),
            conversationSnapshot: snapshot,
            communicationContext: communicationContext,
            progressAlreadyShown: progressAlreadyShown
        )
    }

    private func polishPrompt(
        for snapshot: ConversationSnapshot?,
        conversationInstruction: String? = nil
    ) -> String {
        let contextInstruction = snapshot.flatMap {
            ApplicationContextPolicy.contextInstruction(
                for: $0.applicationContext,
                conversationInstruction: conversationInstruction
            )
        }
        return PromptPolicy.polishPrompt(
            basePrompt: model.prompt,
            contextInstruction: contextInstruction
        )
    }

    private func showConversationProfilePanel(
        for snapshot: ConversationSnapshot,
        title: String,
        context: CapturedTextContext
    ) {
        model.isProcessing = true
        model.statusText = "设置聊天对象…"
        let insertionPoint = textService.insertionPointScreenRect(for: context)
        conversationProfilePanel.show(
            conversationTitle: title,
            at: insertionPoint
        ) { [weak self] decision in
            self?.handleConversationProfileDecision(
                decision,
                snapshot: snapshot,
                context: context
            )
        }
    }

    private func handleConversationProfileDecision(
        _ decision: ConversationProfilePanel.Decision,
        snapshot: ConversationSnapshot,
        context: CapturedTextContext
    ) {
        guard model.isProcessing else { return }
        if case .cancel = decision {
            resetAfterCancelledConversationSelection()
            return
        }
        guard conversationResolver.isTargetOrPoleFrontmost(snapshot) else {
            cancelForChangedConversation()
            return
        }

        conversationResolver.reactivate(snapshot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.model.isProcessing else { return }
            guard self.conversationResolver.matchesCurrentConversation(snapshot) else {
                self.cancelForChangedConversation()
                return
            }
            guard self.textService.isCurrent(context) else {
                self.cancelForChangedText()
                return
            }

            switch decision {
            case .save(let role, let instruction):
                guard let profile = self.model.intelligence.createManualRelationship(
                    for: snapshot,
                    role: role,
                    customInstruction: instruction
                ) else {
                    self.cancelForChangedConversation()
                    return
                }
                self.beginPolish(context: context, snapshot: snapshot, relationship: profile)
            case .useGeneric:
                self.beginPolish(context: context, snapshot: snapshot, relationship: nil)
            case .cancel:
                self.resetAfterCancelledConversationSelection()
            }
        }
    }

    private func beginRewrite(
        context: CapturedTextContext,
        action: RewriteAction,
        prompt: String,
        conversationSnapshot: ConversationSnapshot?,
        communicationContext: CommunicationContext?,
        progressAlreadyShown: Bool = false
    ) {
        model.isProcessing = true
        model.statusText = action.promptDescription
        if !progressAlreadyShown {
            let insertionPoint = textService.insertionPointScreenRect(for: context)
            inputProgressIndicator.show(
                at: insertionPoint,
                operation: action == .translate ? .translation : .optimization
            )
        }

        let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.modelName

        Task { [weak self] in
            guard let self else { return }
            do {
                let result: String
                if action == .polish,
                   let communicationContext,
                   communicationContext.applicationContext.role == .messaging {
                    let first = StructuredRewriteResult(
                        rewrittenText: try await self.client.optimize(
                            text: context.sourceText,
                            apiKey: key,
                            model: selectedModel,
                            prompt: prompt
                        )
                    )
                    let firstFactAudit = FactGuard.audit(
                        sourceText: context.sourceText,
                        result: first,
                        applicationRole: communicationContext.applicationContext.role,
                        expansionRatio: communicationContext.policy.messageExpansionRatio
                    )
                    let firstVoiceAudit = VoiceGuard.audit(
                        sourceText: context.sourceText,
                        outputText: first.rewrittenText,
                        expectedVoice: communicationContext.policy.voice,
                        applicationRole: communicationContext.applicationContext.role
                    )
                    if firstFactAudit.accepted, firstVoiceAudit.accepted {
                        result = first.rewrittenText
                    } else {
                        let issues = firstFactAudit.issues + firstVoiceAudit.issues
                        let retry = StructuredRewriteResult(
                            rewrittenText: try await self.client.optimize(
                                text: context.sourceText,
                                apiKey: key,
                                model: selectedModel,
                                prompt: prompt,
                                retryIssues: issues
                            )
                        )
                        let retryFactAudit = FactGuard.audit(
                            sourceText: context.sourceText,
                            result: retry,
                            applicationRole: communicationContext.applicationContext.role,
                            expansionRatio: communicationContext.policy.messageExpansionRatio
                        )
                        let retryVoiceAudit = VoiceGuard.audit(
                            sourceText: context.sourceText,
                            outputText: retry.rewrittenText,
                            expectedVoice: communicationContext.policy.voice,
                            applicationRole: communicationContext.applicationContext.role
                        )
                        if retryFactAudit.accepted, retryVoiceAudit.accepted {
                            result = retry.rewrittenText
                        } else {
                            throw RewriteSafetyError.rejected(
                                retryFactAudit.issues + retryVoiceAudit.issues
                            )
                        }
                    }
                } else {
                    result = try await self.client.optimize(
                        text: context.sourceText,
                        apiKey: key,
                        model: selectedModel,
                        prompt: prompt
                    )
                }
                try await MainActor.run {
                    if let conversationSnapshot,
                       !self.conversationResolver.matchesCurrentConversation(conversationSnapshot) {
                        throw ConversationContextError.changed
                    }
                    let outcome = OptimizationOutcome.classify(
                        sourceText: context.sourceText,
                        result: result
                    )
                    try self.textService.replace(context: context, with: result)
                    if action == .polish {
                        let relationshipID = communicationContext?.relationship?.id
                        self.recentRewriteFeedbackContext = RecentRewriteFeedbackContext(
                            relationshipID: relationshipID,
                            createdAt: Date()
                        )
                        if self.model.rewriteLearningEnabled, result != context.sourceText {
                            self.model.intelligence.recordPendingRewrite(
                                text: result,
                                relationshipID: relationshipID,
                                conversationID: communicationContext?.relationship?.conversationID
                            )
                        }
                    }
                    let finalCursorUTF16 = context.replacementRange.location
                        + (result as NSString).length
                    self.pendingCompletion = PendingCompletion(
                        context: context,
                        cursorUTF16: finalCursorUTF16,
                        outcome: outcome,
                        action: action
                    )
                    self.perform(
                        #selector(self.finishPendingCompletion),
                        with: nil,
                        afterDelay: 0.08
                    )
                }
            } catch {
                await MainActor.run {
                    NSObject.cancelPreviousPerformRequests(
                        withTarget: self,
                        selector: #selector(self.finishPendingCompletion),
                        object: nil
                    )
                    self.pendingCompletion = nil
                    self.inputProgressIndicator.fail()
                    self.model.isProcessing = false
                    self.model.statusText = self.failureStatusText(for: error)
                }
            }
        }
    }

    private func resetAfterCancelledConversationSelection() {
        model.isProcessing = false
        model.statusText = model.isEnabled ? readyStatusText : "已暂停"
    }

    private func cancelForChangedConversation() {
        model.isProcessing = false
        model.statusText = ConversationContextError.changed.localizedDescription
    }

    private func cancelForChangedText() {
        model.isProcessing = false
        model.statusText = TextEditingError.textChangedWhileWaiting.localizedDescription
    }

    @objc private func finishPendingCompletion() {
        guard let completion = pendingCompletion, model.isProcessing else { return }
        pendingCompletion = nil
        inputProgressIndicator.move(
            to: textService.insertionPointScreenRect(
                for: completion.context,
                cursorUTF16: completion.cursorUTF16
            )
        ) { [weak self] in
            guard let self, self.model.isProcessing else { return }
            self.inputProgressIndicator.finish(
                with: completion.outcome,
                operation: completion.action == .translate ? .translation : .optimization
            )
            self.model.isProcessing = false
            self.model.statusText = self.model.isEnabled ? self.readyStatusText : "已暂停"
        }
    }

    private func showError(_ message: String) {
        model.statusText = message
    }

    private func failureStatusText(for error: Error) -> String {
        if let conversationError = error as? ConversationContextError {
            return conversationError.localizedDescription
        }
        if let editingError = error as? TextEditingError {
            return "上次失败：\(editingError.localizedDescription)"
        }
        if let safetyError = error as? RewriteSafetyError {
            return "上次失败：\(safetyError.localizedDescription)"
        }
        if let qwenError = error as? QwenError {
            return "上次失败：\(qwenError.localizedDescription)"
        }
        return "上次失败：\(error.localizedDescription)"
    }
}

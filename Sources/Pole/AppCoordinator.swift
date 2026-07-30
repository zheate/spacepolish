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

        var performanceName: String {
            switch self {
            case .polish:
                return "polish"
            case .translate:
                return "translate"
            }
        }

        var progressOperation: InputProgressOperation {
            switch self {
            case .polish:
                return .optimization
            case .translate:
                return .translation
            }
        }
    }

    private struct PendingCompletion {
        let context: CapturedTextContext
        let cursorUTF16: Int
        let outcome: OptimizationOutcome
        let action: RewriteAction
        let retried: Bool
        let retryReason: String?
    }

    private struct RecentRewriteFeedbackContext {
        let relationshipID: UUID?
        let historyEntryID: UUID?
        let createdAt: Date
    }

    private final class RewriteAttemptState: @unchecked Sendable {
        var retried = false
        var retryReason: String?
    }

    let model = AppModel()

    private let client = QwenClient()
    private let textService = AccessibilityTextService()
    private let conversationResolver = ConversationResolver()
    private let monitor = DoubleOptionMonitor()
    private let hud = StatusHUD()
    private let rewriteHighlightOverlay = RewriteHighlightOverlay()
    private lazy var inputProgressIndicator = InputProgressIndicator(
        isSoundEnabled: { [weak self] in
            self?.model.soundEffectsEnabled ?? false
        }
    )
    private let conversationProfilePanel = ConversationProfilePanel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var settingsController: SettingsWindowController?
    private var isMonitorStarted = false
    private var pendingCompletion: PendingCompletion?
    private var progressPositionRetryWorkItem: DispatchWorkItem?
    private var recentRewriteFeedbackContext: RecentRewriteFeedbackContext?
    private var rewriteHighlightGeneration = 0
    private var activePerformanceTrace: RewritePerformanceTrace?

    override init() {
        super.init()

        let statusIcon = NSImage(
            systemSymbolName: "sparkle",
            accessibilityDescription: "Pole"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        statusIcon?.isTemplate = true
        statusItem.button?.image = statusIcon
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
            relationshipID: context.relationshipID,
            historyEntryID: context.historyEntryID
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
        guard !model.isProcessing else { return }
        inputProgressIndicator.showFallback(operation: action.progressOperation)

        guard model.hasAPIKey else {
            inputProgressIndicator.fail()
            model.statusText = "请先设置通义千问 API Key"
            return
        }

        let trace = RewritePerformanceTrace(action: action.performanceName)
        activePerformanceTrace = trace
        let captureStartedAt = RewritePerformanceTrace.timestamp()
        let context: CapturedTextContext
        do {
            context = try textService.captureTargetText()
        } catch {
            trace.record(.capture, since: captureStartedAt)
            trace.finish(outcome: "capture_failed", retried: false)
            activePerformanceTrace = nil
            inputProgressIndicator.fail()
            model.statusText = (error as? LocalizedError)?.errorDescription
                ?? "无法读取当前输入框"
            return
        }
        trace.setInputLength(context.sourceText.count)
        trace.record(.capture, since: captureStartedAt)

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
        let contextStartedAt = RewritePerformanceTrace.timestamp()
        let snapshot = conversationResolver.resolveCurrentConversation()
        activePerformanceTrace?.record(
            .conversationContext,
            since: contextStartedAt
        )
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
        showInputProgress(for: context, operation: .optimization)
        let provider = ExternalHelperProvider(executableURL: helperURL)
        let historyStartedAt = RewritePerformanceTrace.timestamp()
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
                self.activePerformanceTrace?.record(
                    .historyContext,
                    since: historyStartedAt
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
                    self.activePerformanceTrace?.record(
                        .historyContext,
                        since: historyStartedAt
                    )
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
        // Ordinary chat polishing must remain one gesture. Unknown contacts use
        // the messaging defaults immediately instead of interrupting the first
        // rewrite with relationship setup.
        beginPolish(context: context, snapshot: snapshot, relationship: nil)
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
            voiceSampleCount: model.intelligence.voice.sampleCount(for: relationship?.id),
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
                sourceText: context.sourceText,
                conversationInstruction: policy.modelInstruction
            ),
            conversationSnapshot: snapshot,
            communicationContext: communicationContext,
            progressAlreadyShown: progressAlreadyShown
        )
    }

    private func polishPrompt(
        for snapshot: ConversationSnapshot?,
        sourceText: String,
        conversationInstruction: String? = nil
    ) -> String {
        let applicationInstruction = snapshot.flatMap {
            ApplicationContextPolicy.contextInstruction(
                for: $0.applicationContext,
                conversationInstruction: conversationInstruction
            )
        }
        let semanticInstruction = SemanticLibraryCatalog.modelInstruction(
            for: sourceText,
            enabled: model.enabledSemanticLibraries
        )
        let contextInstruction = [applicationInstruction, semanticInstruction]
            .compactMap { instruction -> String? in
                guard let instruction else { return nil }
                let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
        return PromptPolicy.polishPrompt(
            basePrompt: model.prompt,
            contextInstruction: contextInstruction.isEmpty ? nil : contextInstruction
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
        rewriteHighlightGeneration &+= 1
        rewriteHighlightOverlay.hide()
        model.isProcessing = true
        model.statusText = action.promptDescription
        if !progressAlreadyShown {
            showInputProgress(
                for: context,
                operation: action == .translate ? .translation : .optimization
            )
        }

        let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.modelName

        Task { [weak self] in
            guard let self else { return }
            let attemptState = RewriteAttemptState()
            do {
                let result: String
                if action == .polish,
                   let communicationContext {
                    let first = StructuredRewriteResult(
                        rewrittenText: try await self.requestOptimization(
                            text: context.sourceText,
                            apiKey: key,
                            model: selectedModel,
                            prompt: prompt,
                            retryIssues: [],
                            stage: .firstModel
                        )
                    )
                    let firstGuardStartedAt = RewritePerformanceTrace.timestamp()
                    let firstFactAudit = FactGuard.audit(
                        sourceText: context.sourceText,
                        result: first,
                        applicationRole: communicationContext.applicationContext.role,
                        expansionRatio: communicationContext.policy.messageExpansionRatio,
                        semanticLibraries: self.model.enabledSemanticLibraries
                    )
                    let firstVoiceAudit = VoiceGuard.audit(
                        sourceText: context.sourceText,
                        outputText: first.rewrittenText,
                        expectedVoice: communicationContext.policy.voice,
                        applicationRole: communicationContext.applicationContext.role
                    )
                    let firstAlignmentAudit = RewriteAlignmentGuard.audit(
                        sourceText: context.sourceText,
                        outputText: first.rewrittenText,
                        applicationRole: communicationContext.applicationContext.role
                    )
                    let firstQualityAudit = RewriteQualityGuard.audit(
                        sourceText: context.sourceText,
                        outputText: first.rewrittenText,
                        applicationRole: communicationContext.applicationContext.role
                    )
                    self.activePerformanceTrace?.record(
                        .firstGuard,
                        since: firstGuardStartedAt
                    )
                    let firstWasSafe = firstFactAudit.accepted
                        && firstVoiceAudit.accepted
                        && firstAlignmentAudit.accepted
                    let firstWasAccepted = firstWasSafe && firstQualityAudit.accepted
                    if firstWasAccepted {
                        result = first.rewrittenText
                    } else {
                        attemptState.retried = true
                        if !firstWasSafe, !firstQualityAudit.accepted {
                            attemptState.retryReason = "safety_and_quality"
                        } else if !firstWasSafe {
                            attemptState.retryReason = "safety"
                        } else {
                            attemptState.retryReason = "quality"
                        }
                        let issues = firstFactAudit.issues
                            + firstVoiceAudit.issues
                            + firstAlignmentAudit.issues
                            + firstQualityAudit.issues
                        let retry = StructuredRewriteResult(
                            rewrittenText: try await self.requestOptimization(
                                text: context.sourceText,
                                apiKey: key,
                                model: selectedModel,
                                prompt: prompt,
                                retryIssues: issues,
                                stage: .retryModel
                            )
                        )
                        let retryGuardStartedAt = RewritePerformanceTrace.timestamp()
                        let retryFactAudit = FactGuard.audit(
                            sourceText: context.sourceText,
                            result: retry,
                            applicationRole: communicationContext.applicationContext.role,
                            expansionRatio: communicationContext.policy.messageExpansionRatio,
                            semanticLibraries: self.model.enabledSemanticLibraries
                        )
                        let retryVoiceAudit = VoiceGuard.audit(
                            sourceText: context.sourceText,
                            outputText: retry.rewrittenText,
                            expectedVoice: communicationContext.policy.voice,
                            applicationRole: communicationContext.applicationContext.role
                        )
                        let retryAlignmentAudit = RewriteAlignmentGuard.audit(
                            sourceText: context.sourceText,
                            outputText: retry.rewrittenText,
                            applicationRole: communicationContext.applicationContext.role
                        )
                        let retryQualityAudit = RewriteQualityGuard.audit(
                            sourceText: context.sourceText,
                            outputText: retry.rewrittenText,
                            applicationRole: communicationContext.applicationContext.role
                        )
                        self.activePerformanceTrace?.record(
                            .retryGuard,
                            since: retryGuardStartedAt
                        )
                        if retryFactAudit.accepted,
                           retryVoiceAudit.accepted,
                           retryAlignmentAudit.accepted,
                           retryQualityAudit.accepted {
                            result = retry.rewrittenText
                        } else if firstWasSafe,
                                  !firstQualityAudit.meaningfullyChanged {
                            // If both attempts fail to produce a safe improvement,
                            // preserving the user's original text is the only honest
                            // fallback. It remains classified as unchanged rather than
                            // being presented as a successful rewrite.
                            result = first.rewrittenText
                        } else {
                            let retrySafetyIssues = retryFactAudit.issues
                                + retryVoiceAudit.issues
                                + retryAlignmentAudit.issues
                            if retrySafetyIssues.isEmpty {
                                throw RewriteSafetyError.qualityRejected(
                                    retryQualityAudit.issues
                                )
                            }
                            throw RewriteSafetyError.rejected(
                                retrySafetyIssues + retryQualityAudit.issues
                            )
                        }
                    }
                } else {
                    result = try await self.requestOptimization(
                        text: context.sourceText,
                        apiKey: key,
                        model: selectedModel,
                        prompt: prompt,
                        retryIssues: [],
                        stage: .firstModel
                    )
                }
                let highlightPlan = action == .polish
                    ? RewriteHighlightPlanner.plan(
                        sourceText: context.sourceText,
                        outputText: result
                    )
                    : RewriteHighlightPlan(ranges: [])
                try await MainActor.run {
                    let writebackStartedAt = RewritePerformanceTrace.timestamp()
                    if let conversationSnapshot,
                       !self.conversationResolver.matchesCurrentConversation(conversationSnapshot) {
                        throw ConversationContextError.changed
                    }
                    let outcome = OptimizationOutcome.classify(
                        sourceText: context.sourceText,
                        result: result
                    )
                    try self.textService.replace(context: context, with: result)
                    if highlightPlan.hasChanges {
                        self.scheduleRewriteHighlights(
                            plan: highlightPlan,
                            context: context,
                            finalCursorUTF16: context.replacementRange.location
                                + (result as NSString).length,
                            generation: self.rewriteHighlightGeneration
                        )
                    }
                    if action == .polish {
                        let relationshipID = communicationContext?.relationship?.id
                        let historyEntryID: UUID?
                        if self.model.rewriteLearningEnabled,
                           let communicationContext {
                            historyEntryID = self.model.intelligence.recordRewrite(
                                sourceText: context.sourceText,
                                rewrittenText: result,
                                applicationRole: communicationContext.applicationContext.role,
                                relationshipID: relationshipID,
                                conversationID: communicationContext.relationship?.conversationID
                            )
                        } else {
                            historyEntryID = nil
                        }
                        self.recentRewriteFeedbackContext = RecentRewriteFeedbackContext(
                            relationshipID: relationshipID,
                            historyEntryID: historyEntryID,
                            createdAt: Date()
                        )
                    }
                    let finalCursorUTF16 = context.replacementRange.location
                        + (result as NSString).length
                    self.pendingCompletion = PendingCompletion(
                        context: context,
                        cursorUTF16: finalCursorUTF16,
                        outcome: outcome,
                        action: action,
                        retried: attemptState.retried,
                        retryReason: attemptState.retryReason
                    )
                    self.activePerformanceTrace?.record(
                        .writeback,
                        since: writebackStartedAt
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
                    self.activePerformanceTrace?.finish(
                        outcome: "failed",
                        retried: attemptState.retried,
                        retryReason: attemptState.retryReason
                    )
                    self.activePerformanceTrace = nil
                }
            }
        }
    }

    private func requestOptimization(
        text: String,
        apiKey: String,
        model: String,
        prompt: String,
        retryIssues: [String],
        stage: RewritePerformanceTrace.Stage
    ) async throws -> String {
        let startedAt = RewritePerformanceTrace.timestamp()
        do {
            let result = try await client.optimize(
                text: text,
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                retryIssues: retryIssues
            )
            activePerformanceTrace?.record(stage, since: startedAt)
            return result
        } catch {
            activePerformanceTrace?.record(stage, since: startedAt)
            throw error
        }
    }

    private func showInputProgress(
        for context: CapturedTextContext,
        operation: InputProgressOperation
    ) {
        progressPositionRetryWorkItem?.cancel()
        progressPositionRetryWorkItem = nil
        attemptToShowInputProgress(
            for: context,
            operation: operation,
            remainingDelays: [0.04, 0.12, 0.24]
        )
    }

    private func scheduleRewriteHighlights(
        plan: RewriteHighlightPlan,
        context: CapturedTextContext,
        finalCursorUTF16: Int,
        generation: Int
    ) {
        let absoluteRanges = plan.ranges.map { range in
            NSRange(
                location: context.replacementRange.location + range.location,
                length: range.length
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.attemptToShowRewriteHighlights(
                ranges: absoluteRanges,
                changeCount: plan.changeCount,
                context: context,
                finalCursorUTF16: finalCursorUTF16,
                generation: generation,
                remainingDelays: [0.20, 0.36]
            )
        }
    }

    private func attemptToShowRewriteHighlights(
        ranges: [NSRange],
        changeCount: Int,
        context: CapturedTextContext,
        finalCursorUTF16: Int,
        generation: Int,
        remainingDelays: [TimeInterval]
    ) {
        guard rewriteHighlightGeneration == generation,
              textService.isTargetApplicationFrontmost(for: context) else {
            return
        }

        let rects = textService.highlightScreenRects(for: ranges, in: context)
        if !rects.isEmpty {
            rewriteHighlightOverlay.show(accessibilityScreenRects: rects)
            return
        }

        guard let delay = remainingDelays.first else {
            rewriteHighlightOverlay.showFallback(
                at: textService.insertionPointScreenRect(
                    for: context,
                    cursorUTF16: finalCursorUTF16
                ),
                changeCount: changeCount
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptToShowRewriteHighlights(
                ranges: ranges,
                changeCount: changeCount,
                context: context,
                finalCursorUTF16: finalCursorUTF16,
                generation: generation,
                remainingDelays: Array(remainingDelays.dropFirst())
            )
        }
    }

    private func attemptToShowInputProgress(
        for context: CapturedTextContext,
        operation: InputProgressOperation,
        remainingDelays: [TimeInterval]
    ) {
        guard model.isProcessing else { return }
        if inputProgressIndicator.show(
            at: textService.insertionPointScreenRect(for: context),
            operation: operation
        ) {
            progressPositionRetryWorkItem = nil
            return
        }

        guard let delay = remainingDelays.first else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptToShowInputProgress(
                for: context,
                operation: operation,
                remainingDelays: Array(remainingDelays.dropFirst())
            )
        }
        progressPositionRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resetAfterCancelledConversationSelection() {
        progressPositionRetryWorkItem?.cancel()
        progressPositionRetryWorkItem = nil
        activePerformanceTrace?.finish(outcome: "cancelled", retried: false)
        activePerformanceTrace = nil
        model.isProcessing = false
        model.statusText = model.isEnabled ? readyStatusText : "已暂停"
    }

    private func cancelForChangedConversation() {
        progressPositionRetryWorkItem?.cancel()
        progressPositionRetryWorkItem = nil
        activePerformanceTrace?.finish(outcome: "conversation_changed", retried: false)
        activePerformanceTrace = nil
        model.isProcessing = false
        model.statusText = ConversationContextError.changed.localizedDescription
    }

    private func cancelForChangedText() {
        progressPositionRetryWorkItem?.cancel()
        progressPositionRetryWorkItem = nil
        activePerformanceTrace?.finish(outcome: "text_changed", retried: false)
        activePerformanceTrace = nil
        model.isProcessing = false
        model.statusText = TextEditingError.textChangedWhileWaiting.localizedDescription
    }

    @objc private func finishPendingCompletion() {
        guard let completion = pendingCompletion, model.isProcessing else { return }
        pendingCompletion = nil
        progressPositionRetryWorkItem?.cancel()
        progressPositionRetryWorkItem = nil
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
            let outcome = completion.outcome == .unchanged ? "unchanged" : "changed"
            self.activePerformanceTrace?.finish(
                outcome: outcome,
                retried: completion.retried,
                retryReason: completion.retryReason
            )
            self.activePerformanceTrace = nil
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

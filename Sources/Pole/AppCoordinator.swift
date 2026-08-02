import AppKit

@MainActor
package final class AppCoordinator: NSObject, NSMenuDelegate {
    private enum RewriteAction {
        case polish
        case expand
        case translate

        var promptDescription: String {
            switch self {
            case .polish:
                return "正在优化…"
            case .expand:
                return "正在适当扩写…"
            case .translate:
                return "正在翻译…"
            }
        }

        var performanceName: String {
            switch self {
            case .polish:
                return "polish"
            case .expand:
                return "expand"
            case .translate:
                return "translate"
            }
        }

        var progressOperation: InputProgressOperation {
            switch self {
            case .polish, .expand:
                return .optimization
            case .translate:
                return .translation
            }
        }

        var rewriteMode: RewriteMode? {
            switch self {
            case .polish:
                return .polish
            case .expand:
                return .expand
            case .translate:
                return nil
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
    private let textIOService = AccessibilityTextIOService()
    private let conversationResolver = ConversationResolver()
    private lazy var conversationContextService = ConversationContextService(
        resolver: conversationResolver
    )
    private let rewriteCoordinator = RewriteCoordinator()
    private let rewritePipeline = RewritePipeline()
    private let recentContextCache = RecentContextCache()
    private let monitor = DoubleOptionMonitor()
    private let hud = StatusHUD()
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
    private var activePerformanceTrace: RewritePerformanceTrace?

    package override init() {
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

    package func start() {
        if model.hasAPIKey {
            validateStoredAPIKey()
        }
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

    package func menuWillOpen(_ menu: NSMenu) {
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

        let expand = NSMenuItem(
            title: "适当扩写当前文本",
            action: #selector(expandCurrentText),
            keyEquivalent: ""
        )
        expand.target = self
        expand.isEnabled = model.canUseAPI && !model.isProcessing
        menu.addItem(expand)

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
        let build = NSMenuItem(title: buildDescription, action: nil, keyEquivalent: "")
        build.isEnabled = false
        menu.addItem(build)
        let quit = NSMenuItem(title: "退出 Pole", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        let isPausing = model.isEnabled
        model.isEnabled.toggle()
        try? model.save()
        if isPausing, rewriteCoordinator.hasActiveRequest {
            rewriteCoordinator.cancel(.paused)
        } else {
            model.statusText = model.isEnabled ? readyStatusText : "已暂停"
        }
    }

    @objc private func expandCurrentText() {
        // Let the status-item menu close and return focus to the original field
        // before capturing the target text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.handleTrigger(.expand)
        }
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

    @objc package func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                model: model,
                onValidateAPIKey: { [weak self] key in
                    guard let self else { throw QwenError.invalidResponse }
                    try await self.client.validateAPIKey(key)
                },
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
        if model.hasAPIKey, model.apiConnectionState == .unknown {
            validateStoredAPIKey()
        }
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

    private var buildDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "开发"
        let build = info["CFBundleVersion"] as? String ?? "未打包"
        let commit = (info["PoleBuildCommit"] as? String).map {
            String($0.prefix(8))
        } ?? "unknown"
        let state = info["PoleBuildState"] as? String ?? "local"
        return "Pole \(version) (\(build)) · \(commit) · \(state)"
    }

    private func handleTrigger(_ action: RewriteAction) {
        guard !model.isProcessing else { return }
        if let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let blockedReason = RewriteTargetSafetyPolicy.blockedReason(
               bundleIdentifier: bundleIdentifier
           ) {
            model.statusText = blockedReason
            hud.show(blockedReason)
            return
        }
        inputProgressIndicator.showFallback(operation: action.progressOperation)

        guard model.canUseAPI else {
            inputProgressIndicator.fail()
            switch model.apiConnectionState {
            case .checking:
                model.statusText = "正在验证通义千问 API Key"
            case .invalid(let message):
                model.statusText = message
            case .unknown, .valid:
                model.statusText = "请先设置通义千问 API Key"
            }
            return
        }

        let requestID = rewriteCoordinator.beginRequest { [weak self] reason in
            self?.handleAutomaticCancellation(reason)
        }
        let trace = RewritePerformanceTrace(action: action.performanceName)
        activePerformanceTrace = trace
        let captureStartedAt = RewritePerformanceTrace.timestamp()
        model.isProcessing = true
        model.statusText = action.promptDescription
        let captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await self.textIOService.captureTargetText()
                try Task.checkCancellation()
                guard self.rewriteCoordinator.isCurrent(requestID) else { return }
                self.completeTriggerCapture(
                    context,
                    action: action,
                    requestID: requestID,
                    captureStartedAt: captureStartedAt,
                    trace: trace
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.rewriteCoordinator.isCurrent(requestID) else { return }
                trace.record(.capture, since: captureStartedAt)
                trace.finish(outcome: "capture_failed", retried: false)
                self.rewriteCoordinator.finish(requestID)
                self.activePerformanceTrace = nil
                self.inputProgressIndicator.fail()
                self.model.isProcessing = false
                self.model.statusText = (error as? LocalizedError)?.errorDescription
                    ?? "无法读取当前输入框"
            }
        }
        rewriteCoordinator.attach(captureTask, to: requestID)
    }

    private func completeTriggerCapture(
        _ context: CapturedTextContext,
        action: RewriteAction,
        requestID: UUID,
        captureStartedAt: UInt64,
        trace: RewritePerformanceTrace
    ) {
        do {
            try RewriteInputPolicy.validate(
                TextRewritePlan(
                    capturedText: context.capturedText,
                    cursorUTF16: context.cursorUTF16,
                    replacementRange: context.replacementRange,
                    sourceText: context.sourceText,
                    isExplicitSelection: context.isExplicitSelection
                )
            )
        } catch {
            trace.finish(outcome: "input_rejected", retried: false)
            rewriteCoordinator.finish(requestID)
            activePerformanceTrace = nil
            inputProgressIndicator.fail()
            model.isProcessing = false
            model.statusText = error.localizedDescription
            hud.show(error.localizedDescription)
            return
        }
        trace.setInputLength(context.sourceText.count)
        trace.record(.capture, since: captureStartedAt)
        rewriteCoordinator.monitor(
            context: context,
            requestID: requestID
        ) { [weak self] reason in
            self?.handleAutomaticCancellation(reason)
        }

        switch action {
        case .polish, .expand:
            let contextStartedAt = RewritePerformanceTrace.timestamp()
            let contextTask = Task { [weak self] in
                guard let self else { return }
                let snapshot = await self.conversationContextService
                    .resolveCurrentConversation()
                guard self.rewriteCoordinator.isCurrent(requestID) else { return }
                self.activePerformanceTrace?.record(
                    .conversationContext,
                    since: contextStartedAt
                )
                self.handlePolishTrigger(
                    context: context,
                    snapshot: snapshot,
                    action: action
                )
            }
            rewriteCoordinator.attach(contextTask, to: requestID)
        case .translate:
            beginRewrite(
                context: context,
                action: .translate,
                prompt: TranslationPolicy.prompt,
                conversationSnapshot: nil,
                communicationContext: nil
            )
        }
    }

    private func handlePolishTrigger(
        context: CapturedTextContext,
        snapshot: ConversationSnapshot?,
        action: RewriteAction = .polish
    ) {
        if action == .polish {
            let applicationContext = snapshot?.applicationContext
                ?? ApplicationContextClassifier.context(bundleIdentifier: "unknown")
            let preflightPlan = AdaptivePolishPolicy.plan(
                for: context.sourceText,
                applicationRole: applicationContext.role
            )
            if !preflightPlan.shouldRequestModel {
                beginRewrite(
                    context: context,
                    action: action,
                    prompt: "",
                    conversationSnapshot: snapshot,
                    communicationContext: nil,
                    adaptivePolishPlan: preflightPlan
                )
                return
            }
        }
        if let snapshot,
           !snapshot.applicationContext.supportsConversationProfiles {
            beginPolish(
                context: context,
                snapshot: snapshot,
                relationship: nil,
                action: action
            )
            return
        }

        guard let snapshot else {
            beginPolish(
                context: context,
                snapshot: nil,
                relationship: nil,
                action: action
            )
            return
        }

        let existing = model.intelligence.relationship(for: snapshot)
        let needsRefresh = existing?.lastAnalyzedAt.map {
            Date().timeIntervalSince($0) >= 86_400
        } ?? true
        if model.historyAnalysisEnabled,
           model.helperURL != nil,
           snapshot.normalizedTitle != nil,
           (action == .expand || needsRefresh) {
            prepareHistoryContext(
                context: context,
                snapshot: snapshot,
                fallback: existing,
                action: action,
                refreshRelationship: needsRefresh
            )
            return
        }
        if let existing {
            beginPolish(
                context: context,
                snapshot: snapshot,
                relationship: existing,
                action: action
            )
            return
        }
        if let inferred = model.intelligence.createInferredRelationship(for: snapshot) {
            beginPolish(
                context: context,
                snapshot: snapshot,
                relationship: inferred,
                action: action
            )
            return
        }
        requestRelationshipOrUseGeneric(
            context: context,
            snapshot: snapshot,
            action: action
        )
    }

    private func prepareHistoryContext(
        context: CapturedTextContext,
        snapshot: ConversationSnapshot,
        fallback: RelationshipProfile?,
        action: RewriteAction,
        refreshRelationship: Bool
    ) {
        guard let helperURL = model.helperURL else {
            beginPolish(
                context: context,
                snapshot: snapshot,
                relationship: fallback,
                action: action
            )
            return
        }
        model.isProcessing = true
        model.statusText = "正在理解当前会话…"
        showInputProgress(for: context, operation: .optimization)
        guard let approvedIdentity = model.approvedHelperIdentity else {
            model.helperStatusText = "需要重新确认 helper 身份"
            beginPolish(
                context: context,
                snapshot: snapshot,
                relationship: fallback,
                action: action
            )
            return
        }
        let provider = ExternalHelperProvider(
            executableURL: helperURL,
            approvedIdentity: approvedIdentity
        )
        let historyStartedAt = RewritePerformanceTrace.timestamp()
        let cacheKey = "\(snapshot.applicationIdentifier)|\(snapshot.normalizedTitle ?? "")"
        guard let requestID = rewriteCoordinator.currentRequestID else { return }
        let historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                if action == .expand,
                   let cached = await self.recentContextCache.context(for: cacheKey) {
                    guard await self.textIOService.isCurrent(context) else {
                        throw TextEditingError.textChangedWhileWaiting
                    }
                    try await MainActor.run {
                        guard self.rewriteCoordinator.isCurrent(requestID) else {
                            throw CancellationError()
                        }
                        guard self.conversationResolver.matchesCurrentConversation(snapshot) else {
                            throw ConversationContextError.changed
                        }
                        let resolved = fallback
                            ?? self.model.intelligence.createInferredRelationship(for: snapshot)
                        self.beginPolish(
                            context: context,
                            snapshot: snapshot,
                            relationship: resolved,
                            progressAlreadyShown: true,
                            action: action,
                            recentContext: cached
                        )
                    }
                    return
                }

                _ = try await provider.capabilities()
                let session = try await provider.resolveSession(for: snapshot)
                let messages = try await provider.history(
                    conversationID: session.id,
                    limit: refreshRelationship ? 200 : 30,
                    days: refreshRelationship ? 30 : 7
                )
                let analysisBundle = await Task.detached(priority: .userInitiated) {
                    let recentContext = action == .expand
                        ? RecentConversationAnalyzer.analyze(messages: messages)
                        : .empty
                    let relationship = refreshRelationship
                        ? RelationshipAnalyzer.analyze(
                            title: snapshot.title,
                            messages: messages
                        )
                        : nil
                    return (recentContext, relationship)
                }.value
                let recentContext = analysisBundle.0
                if action == .expand {
                    await self.recentContextCache.save(recentContext, for: cacheKey)
                }
                let analysis = analysisBundle.1
                guard await self.textIOService.isCurrent(context) else {
                    throw TextEditingError.textChangedWhileWaiting
                }
                self.activePerformanceTrace?.record(
                    .historyContext,
                    since: historyStartedAt
                )
                try await MainActor.run {
                    guard self.rewriteCoordinator.isCurrent(requestID) else {
                        throw CancellationError()
                    }
                    guard self.conversationResolver.matchesCurrentConversation(snapshot) else {
                        throw ConversationContextError.changed
                    }
                    self.model.helperStatusText = "已连接 · \(session.type)"
                    var resolved = fallback
                    if let analysis {
                        resolved = self.model.intelligence.applyAnalysis(
                            analysis,
                            snapshot: snapshot,
                            conversationID: session.id,
                            messages: messages
                        ) ?? fallback
                    }
                    resolved = resolved
                        ?? self.model.intelligence.createInferredRelationship(for: snapshot)
                    self.beginPolish(
                        context: context,
                        snapshot: snapshot,
                        relationship: resolved,
                        progressAlreadyShown: true,
                        action: action,
                        recentContext: recentContext
                    )
                }
            } catch {
                await MainActor.run {
                    if error is CancellationError
                        || !self.rewriteCoordinator.isCurrent(requestID) {
                        return
                    }
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
                            progressAlreadyShown: true,
                            action: action
                        )
                    } else if let inferred = self.model.intelligence.createInferredRelationship(for: snapshot) {
                        self.beginPolish(
                            context: context,
                            snapshot: snapshot,
                            relationship: inferred,
                            progressAlreadyShown: true,
                            action: action
                        )
                    } else {
                        self.inputProgressIndicator.fail()
                        self.model.isProcessing = false
                        self.requestRelationshipOrUseGeneric(
                            context: context,
                            snapshot: snapshot,
                            action: action
                        )
                    }
                }
            }
        }
        rewriteCoordinator.attach(historyTask, to: requestID)
    }

    private func requestRelationshipOrUseGeneric(
        context: CapturedTextContext,
        snapshot: ConversationSnapshot,
        action: RewriteAction = .polish
    ) {
        // Ordinary chat polishing must remain one gesture. Unknown contacts use
        // the messaging defaults immediately instead of interrupting the first
        // rewrite with relationship setup.
        beginPolish(
            context: context,
            snapshot: snapshot,
            relationship: nil,
            action: action
        )
    }

    private func beginPolish(
        context: CapturedTextContext,
        snapshot: ConversationSnapshot?,
        relationship: RelationshipProfile?,
        progressAlreadyShown: Bool = false,
        action: RewriteAction = .polish,
        recentContext: RecentConversationContext = .empty
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
        let adaptivePolishPlan = action == .polish
            ? AdaptivePolishPolicy.plan(
                for: context.sourceText,
                applicationRole: applicationContext.role
            )
            : nil
        let expansionPlan = action == .expand
            ? ContextualExpansionPlanner.plan(
                sourceText: context.sourceText,
                communicationContext: communicationContext,
                recentContext: recentContext
            )
            : nil
        beginRewrite(
            context: context,
            action: action,
            prompt: rewritePrompt(
                action: action,
                for: snapshot,
                sourceText: context.sourceText,
                conversationInstruction: policy.modelInstruction,
                adaptivePolishPlan: adaptivePolishPlan,
                expansionPlan: expansionPlan
            ),
            conversationSnapshot: snapshot,
            communicationContext: communicationContext,
            progressAlreadyShown: progressAlreadyShown,
            adaptivePolishPlan: adaptivePolishPlan,
            expansionPlan: expansionPlan
        )
    }

    private func rewritePrompt(
        action: RewriteAction,
        for snapshot: ConversationSnapshot?,
        sourceText: String,
        conversationInstruction: String? = nil,
        adaptivePolishPlan: AdaptivePolishPlan? = nil,
        expansionPlan: ContextualExpansionPlan? = nil
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
        switch action {
        case .polish:
            return PromptPolicy.polishPrompt(
                basePrompt: model.prompt,
                contextInstruction: contextInstruction.isEmpty ? nil : contextInstruction,
                adaptivePlan: adaptivePolishPlan
            )
        case .expand:
            let expansionContext = [
                contextInstruction.isEmpty ? nil : contextInstruction,
                expansionPlan?.modelInstruction
            ]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            return PromptPolicy.expansionPrompt(
                contextInstruction: expansionContext.isEmpty ? nil : expansionContext
            )
        case .translate:
            return TranslationPolicy.prompt
        }
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
            Task { @MainActor [weak self] in
                guard let self, self.model.isProcessing else { return }
                guard self.conversationResolver.matchesCurrentConversation(snapshot) else {
                    self.cancelForChangedConversation()
                    return
                }
                guard await self.textIOService.isCurrent(context) else {
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
    }

    private func beginRewrite(
        context: CapturedTextContext,
        action: RewriteAction,
        prompt: String,
        conversationSnapshot: ConversationSnapshot?,
        communicationContext: CommunicationContext?,
        progressAlreadyShown: Bool = false,
        adaptivePolishPlan: AdaptivePolishPlan? = nil,
        expansionPlan: ContextualExpansionPlan? = nil
    ) {
        model.isProcessing = true
        model.statusText = adaptivePolishPlan?.progressDescription
            ?? action.promptDescription
        if !progressAlreadyShown {
            showInputProgress(
                for: context,
                operation: action.progressOperation
            )
        }

        if let adaptivePolishPlan,
           !adaptivePolishPlan.shouldRequestModel {
            recentRewriteFeedbackContext = nil
            pendingCompletion = PendingCompletion(
                context: context,
                cursorUTF16: context.replacementRange.location
                    + (context.sourceText as NSString).length,
                outcome: .unchanged,
                action: action,
                retried: false,
                retryReason: nil
            )
            perform(
                #selector(finishPendingCompletion),
                with: nil,
                afterDelay: 0.08
            )
            return
        }

        let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.modelName

        guard let requestID = rewriteCoordinator.currentRequestID else { return }
        let rewriteTask = Task { [weak self] in
            guard let self else { return }
            let attemptState = RewriteAttemptState()
            do {
                let result: String
                if let rewriteMode = action.rewriteMode,
                   let communicationContext {
                    let lengthBudget: RewriteLengthBudget?
                    switch rewriteMode {
                    case .expand:
                        lengthBudget = expansionPlan?.lengthBudget ?? .expansion
                    case .polish:
                        lengthBudget = adaptivePolishPlan?.lengthBudget
                    }
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
                    let firstAudit = await self.rewritePipeline.audit(
                        sourceText: context.sourceText,
                        result: first,
                        applicationRole: communicationContext.applicationContext.role,
                        expansionRatio: communicationContext.policy.messageExpansionRatio,
                        semanticLibraries: self.model.enabledSemanticLibraries,
                        expectedVoice: communicationContext.policy.voice,
                        rewriteMode: rewriteMode,
                        lengthBudget: lengthBudget,
                        expansionPlan: expansionPlan
                    )
                    self.activePerformanceTrace?.record(
                        .firstGuard,
                        since: firstGuardStartedAt
                    )
                    let firstWasSafe = firstAudit.isSafe
                    let firstWasQualityAccepted = firstAudit.isQualityAccepted
                    let firstWasAccepted = firstWasSafe && firstWasQualityAccepted
                    if firstWasAccepted {
                        result = first.rewrittenText
                    } else {
                        attemptState.retried = true
                        if !firstWasSafe, !firstWasQualityAccepted {
                            attemptState.retryReason = "safety_and_quality"
                        } else if !firstWasSafe {
                            attemptState.retryReason = "safety"
                        } else {
                            attemptState.retryReason = "quality"
                        }
                        let issues = firstAudit.issues
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
                        let retryAudit = await self.rewritePipeline.audit(
                            sourceText: context.sourceText,
                            result: retry,
                            applicationRole: communicationContext.applicationContext.role,
                            expansionRatio: communicationContext.policy.messageExpansionRatio,
                            semanticLibraries: self.model.enabledSemanticLibraries,
                            expectedVoice: communicationContext.policy.voice,
                            rewriteMode: rewriteMode,
                            lengthBudget: lengthBudget,
                            expansionPlan: expansionPlan
                        )
                        self.activePerformanceTrace?.record(
                            .retryGuard,
                            since: retryGuardStartedAt
                        )
                        if retryAudit.isSafe, retryAudit.isQualityAccepted {
                            result = retry.rewrittenText
                        } else if firstWasSafe,
                                  !firstAudit.quality.meaningfullyChanged {
                            // If both attempts fail to produce a safe improvement,
                            // preserving the user's original text is the only honest
                            // fallback. It remains classified as unchanged rather than
                            // being presented as a successful rewrite.
                            result = first.rewrittenText
                        } else {
                            let retrySafetyIssues = retryAudit.fact.issues
                                + retryAudit.voice.issues
                                + retryAudit.alignment.issues
                            if retrySafetyIssues.isEmpty {
                                throw RewriteSafetyError.qualityRejected(
                                    retryAudit.quality.issues
                                        + (retryAudit.contextual?.issues ?? [])
                                )
                            }
                            throw RewriteSafetyError.rejected(
                                retrySafetyIssues
                                    + retryAudit.quality.issues
                                    + (retryAudit.contextual?.issues ?? [])
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
                let writebackStartedAt = RewritePerformanceTrace.timestamp()
                try await MainActor.run {
                    guard self.rewriteCoordinator.isCurrent(requestID) else {
                        throw CancellationError()
                    }
                    if let conversationSnapshot,
                       !self.conversationResolver.matchesCurrentConversation(conversationSnapshot) {
                        throw ConversationContextError.changed
                    }
                    guard self.rewriteCoordinator.prepareForCommit(requestID) else {
                        throw CancellationError()
                    }
                }
                try await self.textIOService.replace(context: context, with: result)
                try await MainActor.run {
                    guard self.rewriteCoordinator.isCurrent(requestID) else {
                        throw CancellationError()
                    }
                    let outcome = OptimizationOutcome.classify(
                        sourceText: context.sourceText,
                        result: result
                    )
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
                    if error is CancellationError
                        || !self.rewriteCoordinator.isCurrent(requestID) {
                        return
                    }
                    NSObject.cancelPreviousPerformRequests(
                        withTarget: self,
                        selector: #selector(self.finishPendingCompletion),
                        object: nil
                    )
                    self.pendingCompletion = nil
                    self.inputProgressIndicator.fail()
                    self.model.isProcessing = false
                    if let qwenError = error as? QwenError,
                       qwenError.isAuthenticationFailure {
                        self.model.markAPIKeyInvalid(qwenError.localizedDescription)
                    }
                    self.model.statusText = self.failureStatusText(for: error)
                    self.rewriteCoordinator.finish(requestID)
                    self.activePerformanceTrace?.finish(
                        outcome: "failed",
                        retried: attemptState.retried,
                        retryReason: attemptState.retryReason
                    )
                    self.activePerformanceTrace = nil
                }
            }
        }
        rewriteCoordinator.attach(rewriteTask, to: requestID)
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
        rewriteCoordinator.finish()
        model.isProcessing = false
        model.statusText = model.isEnabled ? readyStatusText : "已暂停"
    }

    private func cancelForChangedConversation() {
        if rewriteCoordinator.hasActiveRequest {
            rewriteCoordinator.cancel(.targetChanged)
        } else {
            handleAutomaticCancellation(.targetChanged)
        }
    }

    private func cancelForChangedText() {
        if rewriteCoordinator.hasActiveRequest {
            rewriteCoordinator.cancel(.textChanged)
        } else {
            handleAutomaticCancellation(.textChanged)
        }
    }

    private func handleAutomaticCancellation(_ reason: RewriteCancellationReason) {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(finishPendingCompletion),
            object: nil
        )
        pendingCompletion = nil
        progressPositionRetryWorkItem?.cancel()
        progressPositionRetryWorkItem = nil
        inputProgressIndicator.fail()
        activePerformanceTrace?.finish(
            outcome: reason.performanceOutcome,
            retried: false
        )
        activePerformanceTrace = nil
        model.isProcessing = false
        model.statusText = reason.statusText
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
                operation: completion.action.progressOperation
            )
            let outcome = completion.outcome == .unchanged ? "unchanged" : "changed"
            self.activePerformanceTrace?.finish(
                outcome: outcome,
                retried: completion.retried,
                retryReason: completion.retryReason
            )
            self.activePerformanceTrace = nil
            self.rewriteCoordinator.finish()
            self.model.isProcessing = false
            self.model.statusText = self.model.isEnabled ? self.readyStatusText : "已暂停"
        }
    }

    private func showError(_ message: String) {
        model.statusText = message
    }

    private func validateStoredAPIKey() {
        let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        model.markAPIKeyChecking()
        if AccessibilityPermission.isTrusted {
            model.statusText = "正在验证通义千问 API Key…"
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.validateAPIKey(key)
                await MainActor.run {
                    guard key == self.model.apiKey
                        .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    self.model.markAPIKeyValid()
                    self.settingsController?.refreshAPIConnectionState()
                    self.model.statusText = AccessibilityPermission.isTrusted
                        ? (self.model.isEnabled ? self.readyStatusText : "已暂停")
                        : "等待辅助功能授权"
                }
            } catch {
                await MainActor.run {
                    guard key == self.model.apiKey
                        .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    if let qwenError = error as? QwenError {
                        switch qwenError {
                        case .authenticationFailed, .modelUnavailable:
                            let message = qwenError.localizedDescription
                            self.model.markAPIKeyInvalid(message)
                            self.model.statusText = message
                            self.openSettings()
                            return
                        default:
                            break
                        }
                    }
                    self.model.markAPIKeyUnknown()
                    self.settingsController?.refreshAPIConnectionState()
                    if AccessibilityPermission.isTrusted {
                        self.model.statusText = "暂时无法验证通义千问连接"
                    }
                }
            }
        }
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

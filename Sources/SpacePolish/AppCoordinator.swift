import AppKit

final class AppCoordinator: NSObject, NSMenuDelegate {
    let model = AppModel()

    private let client = DeepSeekClient()
    private let textService = AccessibilityTextService()
    private let monitor = TripleSpaceMonitor()
    private let hud = StatusHUD()
    private let inputProgressIndicator = InputProgressIndicator()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var settingsController: SettingsWindowController?
    private var isMonitorStarted = false

    override init() {
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "wand.and.stars",
            accessibilityDescription: "SpacePolish"
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
        monitor.onTrigger = { [weak self] in
            self?.handleTrigger()
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
        if !model.hasAPIKey {
            model.statusText = "请设置 DeepSeek API Key"
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
            title: model.isEnabled ? "暂停三空格触发" : "启用三空格触发",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

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
        let quit = NSMenuItem(title: "退出 SpacePolish", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        model.isEnabled.toggle()
        try? model.save()
        model.statusText = model.isEnabled ? "已启用" : "已暂停"
    }

    @objc func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                model: model,
                onSave: { [weak self] in self?.saveSettings() },
                onRequestPermission: { [weak self] in self?.requestPermission() }
            )
        }
        settingsController?.present()
    }

    @objc private func requestPermission() {
        AccessibilityPermission.request()
        AccessibilityPermission.openSystemSettings()
        model.statusText = "授权后请切回 SpacePolish"
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
            model.statusText = model.isEnabled ? "已启用：连续输入三个空格" : "已暂停"
        } catch {
            model.statusText = "无法监听键盘"
            showError(error.localizedDescription)
        }
    }

    private func handleTrigger() {
        guard model.hasAPIKey else {
            showError("请先在设置中填写 DeepSeek API Key")
            openSettings()
            return
        }
        guard !model.isProcessing else { return }

        let context: CapturedTextContext
        do {
            context = try textService.captureAndRemoveTriggerSpaces()
        } catch {
            showError(error.localizedDescription)
            return
        }

        model.isProcessing = true
        model.statusText = "正在优化…"
        let insertionPoint = textService.insertionPointScreenRect(for: context)
        inputProgressIndicator.show(at: insertionPoint)

        let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.modelName
        let prompt = model.prompt

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.optimize(
                    text: context.sourceText,
                    apiKey: key,
                    model: selectedModel,
                    prompt: prompt
                )
                try await MainActor.run {
                    let outcome = OptimizationOutcome.classify(
                        sourceText: context.sourceText,
                        result: result
                    )
                    try self.textService.replace(context: context, with: result)
                    self.inputProgressIndicator.finish(with: outcome)
                    self.model.isProcessing = false
                    self.model.statusText = self.model.isEnabled
                        ? "已启用：连续输入三个空格"
                        : "已暂停"
                }
            } catch {
                await MainActor.run {
                    self.inputProgressIndicator.hide()
                    self.model.isProcessing = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func showError(_ message: String) {
        model.statusText = message
        hud.show(message, isError: true, duration: 3.2)
        NSSound.beep()
    }
}

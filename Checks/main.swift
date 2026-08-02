import AppKit
import Foundation
#if SWIFT_PACKAGE
@testable import PoleCore
#endif

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func expectThrow(_ name: String, _ operation: () throws -> Void) {
    do {
        try operation()
        failures += 1
        print("FAIL  \(name)")
    } catch {
        print("PASS  \(name)")
    }
}

private final class AsyncResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }

    func get() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func waitForAsync<T>(
    _ operation: @escaping @Sendable () async throws -> T
) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<T>()
    Task.detached {
        do { box.set(.success(try await operation())) }
        catch { box.set(.failure(error)) }
        semaphore.signal()
    }
    semaphore.wait()
    return box.get()!
}

func runPoleRegressionChecks() -> Int {
failures = 0

do {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let first = NSPasteboardItem()
    first.setString("原始文本", forType: .string)
    first.setData(Data("<b>原始文本</b>".utf8), forType: .html)
    let second = NSPasteboardItem()
    second.setString("第二项", forType: .string)
    pasteboard.writeObjects([first, second])

    let transaction = ClipboardTransaction(pasteboard: pasteboard)
    check(transaction.writeString("Pole 临时内容"), "剪贴板事务可以写入临时内容")
    transaction.restoreIfOwned()
    check(
        pasteboard.pasteboardItems?.count == 2
            && pasteboard.pasteboardItems?.first?.string(forType: .string) == "原始文本"
            && pasteboard.pasteboardItems?.first?.data(forType: .html)
                == Data("<b>原始文本</b>".utf8),
        "剪贴板事务完整恢复多项目和多类型内容"
    )
}

do {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("原始内容", forType: .string)

    let transaction = ClipboardTransaction(pasteboard: pasteboard)
    check(transaction.writeString("Pole 临时内容"), "剪贴板事务记录所有权")
    pasteboard.clearContents()
    pasteboard.setString("用户新复制的内容", forType: .string)
    transaction.restoreIfOwned()
    check(
        pasteboard.string(forType: .string) == "用户新复制的内容",
        "外部剪贴板变化后绝不恢复旧内容"
    )
}

do {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()

    let emptyTransaction = ClipboardTransaction(pasteboard: pasteboard)
    check(emptyTransaction.writeString("Pole 临时内容"), "空剪贴板可以进入事务")
    emptyTransaction.restoreIfOwned()
    check(
        pasteboard.pasteboardItems?.isEmpty != false,
        "空剪贴板在事务结束后恢复为空"
    )

    pasteboard.clearContents()
    pasteboard.setString("原始内容", forType: .string)
    let claimedTransaction = ClipboardTransaction(pasteboard: pasteboard)
    check(claimedTransaction.writeString("复制前标记"), "读取事务写入专用标记")
    pasteboard.clearContents()
    pasteboard.setString("目标应用复制结果", forType: .string)
    check(claimedTransaction.claimCurrentContents(), "读取事务可以重新取得所有权")
    pasteboard.clearContents()
    pasteboard.setString("用户随后复制的内容", forType: .string)
    claimedTransaction.restoreIfOwned()
    check(
        pasteboard.string(forType: .string) == "用户随后复制的内容",
        "读取事务取得所有权后仍不覆盖后续外部复制"
    )
}

do {
    let fullBoundary = String(repeating: "文", count: 4_000)
    let fullPlan = try TextRangePlanner.plan(
        text: fullBoundary,
        selectedRange: NSRange(location: (fullBoundary as NSString).length, length: 0)
    )
    try RewriteInputPolicy.validate(fullPlan)
    check(!fullPlan.isExplicitSelection, "全文 4,000 字符边界允许处理")

    let tooLong = String(repeating: "文", count: 4_001)
    let tooLongPlan = try TextRangePlanner.plan(
        text: tooLong,
        selectedRange: NSRange(location: (tooLong as NSString).length, length: 0)
    )
    do {
        try RewriteInputPolicy.validate(tooLongPlan)
        check(false, "全文超过 4,000 字符时要求选区")
    } catch {
        check(error as? RewriteInputError == .wholeFieldTooLong, "全文超过 4,000 字符时要求选区")
    }

    let selectedBoundary = String(repeating: "🙂", count: 12_000)
    let selectedPlan = try TextRangePlanner.plan(
        text: selectedBoundary,
        selectedRange: NSRange(location: 0, length: (selectedBoundary as NSString).length)
    )
    try RewriteInputPolicy.validate(selectedPlan)
    check(selectedPlan.isExplicitSelection, "显式 Emoji 选区按 12,000 个 Character 计数")

    let selectedTooLong = String(repeating: "文", count: 12_001)
    let selectedTooLongPlan = try TextRangePlanner.plan(
        text: selectedTooLong,
        selectedRange: NSRange(location: 0, length: (selectedTooLong as NSString).length)
    )
    do {
        try RewriteInputPolicy.validate(selectedTooLongPlan)
        check(false, "选区超过 12,000 字符时拒绝请求")
    } catch {
        check(error as? RewriteInputError == .selectionTooLong, "选区超过 12,000 字符时拒绝请求")
    }
} catch {
    check(false, "文本输入限制检查抛出异常：\(error)")
}

let coordinatorResult = MainActor.assumeIsolated {
    let coordinator = RewriteCoordinator()
    var observedCancellation: RewriteCancellationReason?
    let firstRequest = coordinator.beginRequest()
    let firstTask = Task<Void, Never> {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
    coordinator.attach(firstTask, to: firstRequest)

    let secondRequest = coordinator.beginRequest { reason in
        observedCancellation = reason
    }
    let staleTask = Task<Void, Never> {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
    coordinator.attach(staleTask, to: firstRequest)
    let lateResultRejected = !coordinator.isCurrent(firstRequest)
        && coordinator.isCurrent(secondRequest)
        && firstTask.isCancelled
        && staleTask.isCancelled

    let activeTask = Task<Void, Never> {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
    coordinator.attach(activeTask, to: secondRequest)
    coordinator.cancel(.paused)
    return (
        lateResultRejected,
        activeTask.isCancelled && !coordinator.hasActiveRequest,
        observedCancellation == .paused
    )
}
check(coordinatorResult.0, "新请求会取消旧任务并拒绝迟到结果")
check(coordinatorResult.1, "暂停会取消当前任务并清理活动请求")
check(coordinatorResult.2, "采集阶段暂停也会立即更新取消状态")

check(
    RewriteCancellationReason.applicationChanged.statusText.contains("前台应用已切换")
        && RewriteCancellationReason.targetChanged.statusText.contains("输入目标已切换")
        && RewriteCancellationReason.textChanged.statusText.contains("输入内容已变化"),
    "自动取消原因向用户说明具体目标变化"
)

do {
    let lockURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pole-single-instance-\(UUID().uuidString).lock")
    guard let firstLock = SingleInstanceLock.acquire(fileURL: lockURL) else {
        throw NSError(domain: "PoleChecks", code: 1)
    }
    check(
        SingleInstanceLock.acquire(fileURL: lockURL) == nil,
        "单实例锁拒绝第二个 Pole 进程"
    )
    firstLock.release()
    let replacementLock = SingleInstanceLock.acquire(fileURL: lockURL)
    check(replacementLock != nil, "Pole 退出后单实例锁可重新获取")
    replacementLock?.release()
    try? FileManager.default.removeItem(at: lockURL)
} catch {
    failures += 1
    print("FAIL  单实例锁检查抛出异常：\(error)")
}

do {
    let models = Data(
        #"{"data":[{"id":"qwen3.7-plus"},{"id":"qwen3.6-flash"}]}"#.utf8
    )
    try QwenCredentialValidationPolicy.validate(
        statusCode: 200,
        data: models,
        requiredModel: QwenClient.defaultModel
    )
    check(true, "Qwen 凭证校验接受可用模型")
} catch {
    check(false, "Qwen 凭证校验接受可用模型")
}

do {
    try QwenCredentialValidationPolicy.validate(
        statusCode: 401,
        data: Data(#"{"error":{"message":"invalid key"}}"#.utf8),
        requiredModel: QwenClient.defaultModel
    )
    check(false, "Qwen 凭证校验识别失效 API Key")
} catch let error as QwenError {
    check(error.isAuthenticationFailure, "Qwen 凭证校验识别失效 API Key")
} catch {
    check(false, "Qwen 凭证校验识别失效 API Key")
}

do {
    try QwenCredentialValidationPolicy.validate(
        statusCode: 200,
        data: Data(#"{"data":[{"id":"qwen3.6-flash"}]}"#.utf8),
        requiredModel: QwenClient.defaultModel
    )
    check(false, "Qwen 凭证校验拒绝不可用模型")
} catch let error as QwenError {
    if case .modelUnavailable(let model) = error {
        check(model == QwenClient.defaultModel, "Qwen 凭证校验拒绝不可用模型")
    } else {
        check(false, "Qwen 凭证校验拒绝不可用模型")
    }
} catch {
    check(false, "Qwen 凭证校验拒绝不可用模型")
}

do {
    let input = "这个表达有一点不太好"
    let plan = try TextRangePlanner.plan(
        text: input,
        selectedRange: NSRange(location: (input as NSString).length, length: 0)
    )
    check(plan.capturedText == input, "Option 触发不修改原文")
    check(plan.sourceText == input, "无选区时选择全部正文")
    check(
        plan.replacementRange == NSRange(location: 0, length: (input as NSString).length),
        "无选区时计算全文 UTF-16 范围"
    )
} catch {
    failures += 1
    print("FAIL  全文规划抛出异常：\(error)")
}

do {
    let input = "第一段也要优化\n第二段也要优化"
    let plan = try TextRangePlanner.plan(
        text: input,
        selectedRange: NSRange(location: 3, length: 0)
    )
    check(plan.sourceText == input, "无选区时忽略光标位置并优化全文")
    check(
        plan.cursorUTF16 == 3,
        "保留触发时光标位置用于进度提示"
    )
} catch {
    failures += 1
    print("FAIL  多段全文规划抛出异常：\(error)")
}

do {
    let input = "开头保持  只优化这里  结尾保持"
    let selected = (input as NSString).range(of: "只优化这里  ")
    let plan = try TextRangePlanner.plan(
        text: input,
        selectedRange: selected
    )
    check(plan.sourceText == "只优化这里  ", "有选区时只发送所选内容")
    check(plan.replacementRange == selected, "精确保留所选 UTF-16 范围")
    let commit = try TextCommitPlanner.plan(
        currentText: input,
        capturedText: plan.capturedText,
        sourceRange: plan.replacementRange,
        replacement: "已经优化"
    )
    check(commit.updatedText == "开头保持  已经优化结尾保持", "只替换所选内容")
    check(commit.cursorUTF16 == 10, "选区写回后光标位于结果末尾")
} catch {
    failures += 1
    print("FAIL  选区规划抛出异常：\(error)")
}

do {
    let input = "前缀🙂需要优化后缀"
    let selectedText = "🙂需要优化"
    let selected = (input as NSString).range(of: selectedText)
    let plan = try TextRangePlanner.plan(
        text: input,
        selectedRange: selected
    )
    check(plan.sourceText == selectedText, "选区范围正确处理 emoji 的 UTF-16 长度")
    check(plan.replacementRange == selected, "emoji 选区范围不偏移")
} catch {
    failures += 1
    print("FAIL  emoji 选区规划抛出异常：\(error)")
}

do {
    let input = "第一段\n第二段"
    let selected = (input as NSString).range(of: "一段\n第二")
    let plan = try TextRangePlanner.plan(text: input, selectedRange: selected)
    check(plan.sourceText == "一段\n第二", "跨段选区保持原始边界")
} catch {
    failures += 1
    print("FAIL  跨段选区规划抛出异常：\(error)")
}

expectThrow("拒绝超出文本范围的选区") {
    let input = "光标位置异常"
    _ = try TextRangePlanner.plan(
        text: input,
        selectedRange: NSRange(location: (input as NSString).length + 1, length: 0)
    )
}

check(
    UTF16TextRangeValidator.isValid(
        NSRange(location: 2, length: 2),
        in: "A🙂B"
    ),
    "统一范围校验按 UTF-16 计算 emoji 长度"
)
check(
    !UTF16TextRangeValidator.isValid(
        NSRange(location: -1, length: 1),
        in: "正文"
    ),
    "统一范围校验拒绝负位置"
)

do {
    let input = "原文需要优化"
    let rewrite = try TextRangePlanner.plan(
        text: input,
        selectedRange: NSRange(location: 2, length: 0)
    )
    let commit = try TextCommitPlanner.plan(
        currentText: input,
        capturedText: rewrite.capturedText,
        sourceRange: rewrite.replacementRange,
        replacement: "优化后的文字"
    )
    check(commit.updatedText == "优化后的文字", "写回优化后的正文")
    check(commit.cursorUTF16 == 6, "写回后光标位于结果末尾")
} catch {
    failures += 1
    print("FAIL  正文提交抛出异常：\(error)")
}

expectThrow("等待期间真实编辑仍拒绝覆盖") {
    let input = "原文需要优化"
    let rewrite = try TextRangePlanner.plan(
        text: input,
        selectedRange: NSRange(location: (input as NSString).length, length: 0)
    )
    _ = try TextCommitPlanner.plan(
        currentText: "用户已经修改",
        capturedText: rewrite.capturedText,
        sourceRange: rewrite.replacementRange,
        replacement: "优化后的文字"
    )
}

do {
    let captured = "第一行\r\n第二行\u{200B}"
    let current = "第一行\n第二行"
    let commit = try KeyboardTextCommitPlanner.plan(
        currentText: current,
        capturedText: captured,
        sourceRange: NSRange(location: 0, length: (captured as NSString).length),
        replacement: "优化结果"
    )
    check(commit.updatedText == "优化结果", "键盘回退允许微信等价换行和零宽占位差异")
    check(
        commit.replacementRange == NSRange(location: 0, length: (current as NSString).length),
        "等价全文写回使用当前输入框的真实范围"
    )
} catch {
    failures += 1
    print("FAIL  键盘回退等价文本提交抛出异常：\(error)")
}

expectThrow("键盘回退仍拒绝真实文字变化") {
    _ = try KeyboardTextCommitPlanner.plan(
        currentText: "用户补充了新内容",
        capturedText: "原文",
        sourceRange: NSRange(location: 0, length: 2),
        replacement: "优化结果"
    )
}

expectThrow("键盘回退选区模式不放宽文本一致性") {
    _ = try KeyboardTextCommitPlanner.plan(
        currentText: "前文\n后文",
        capturedText: "前文\r\n后文",
        sourceRange: NSRange(location: 0, length: 2),
        replacement: "优化"
    )
}

expectThrow("提交阶段拒绝异常负范围") {
    _ = try TextCommitPlanner.plan(
        currentText: "原文",
        capturedText: "原文",
        sourceRange: NSRange(location: -1, length: 1),
        replacement: "结果"
    )
}

do {
    let input = "前文需要优化后文"
    let selected = (input as NSString).range(of: "需要优化")
    let rewrite = try TextRangePlanner.plan(
        text: input,
        selectedRange: selected
    )
    let commit = try TextCommitPlanner.plan(
        currentText: input,
        capturedText: rewrite.capturedText,
        sourceRange: rewrite.replacementRange,
        replacement: "已经优化"
    )
    check(commit.updatedText == "前文已经优化后文", "保留选区之外的文本")
    check(
        commit.cursorUTF16 == ("前文已经优化" as NSString).length,
        "局部写回后光标位于优化结果末尾"
    )
} catch {
    failures += 1
    print("FAIL  局部选区提交抛出异常：\(error)")
}

expectThrow("拒绝空白全文") {
    let input = "  \n"
    _ = try TextRangePlanner.plan(
        text: input,
        selectedRange: NSRange(location: 1, length: 0)
    )
}

expectThrow("拒绝纯空白选区") {
    let input = "正文   结尾"
    _ = try TextRangePlanner.plan(
        text: input,
        selectedRange: NSRange(location: 2, length: 3)
    )
}

do {
    let input = "重复内容和重复内容"
    let secondRange = (input as NSString).range(of: "重复内容", options: .backwards)
    let resolved = try TextSelectionResolver.resolve(
        text: input,
        copiedSelection: "重复内容",
        accessibilityRange: secondRange
    )
    check(resolved == secondRange, "键盘回退优先使用辅助功能选区定位重复文字")
} catch {
    failures += 1
    print("FAIL  键盘回退选区定位抛出异常：\(error)")
}

do {
    let input = "前缀唯一选区后缀"
    let expected = (input as NSString).range(of: "唯一选区")
    let resolved = try TextSelectionResolver.resolve(
        text: input,
        copiedSelection: "唯一选区",
        accessibilityRange: nil
    )
    check(resolved == expected, "键盘回退可定位唯一的已复制选区")
} catch {
    failures += 1
    print("FAIL  唯一选区定位抛出异常：\(error)")
}

expectThrow("键盘回退拒绝猜测重复选区位置") {
    _ = try TextSelectionResolver.resolve(
        text: "重复重复",
        copiedSelection: "重复",
        accessibilityRange: nil
    )
}

do {
    let input = "没有选区时优化全文"
    let caret = NSRange(location: 3, length: 0)
    let resolved = try TextSelectionResolver.resolve(
        text: input,
        copiedSelection: nil,
        accessibilityRange: caret
    )
    check(resolved == caret, "键盘回退保留无选区时的光标位置")
} catch {
    failures += 1
    print("FAIL  无选区光标定位抛出异常：\(error)")
}

check(
    CaretRecoveryPolicy.action(
        currentRange: CFRange(location: 12, length: 0),
        expectedCursor: 12,
        isFinalCheckpoint: false
    ) == .keepMonitoring,
    "光标首次正确后仍继续观察稳定窗口"
)
check(
    CaretRecoveryPolicy.action(
        currentRange: CFRange(location: 12, length: 0),
        expectedCursor: 12,
        isFinalCheckpoint: true
    ) == .stop,
    "稳定窗口最后一次确认正确后才结束恢复"
)
check(
    CaretRecoveryPolicy.action(
        currentRange: CFRange(location: 0, length: 0),
        expectedCursor: 12,
        isFinalCheckpoint: false
    ) == .repairSelection,
    "Electron 延迟把光标重置到开头时会再次修复"
)
check(
    CaretRecoveryPolicy.action(
        currentRange: CFRange(location: 0, length: 12),
        expectedCursor: 12,
        isFinalCheckpoint: false
    ) == .repairSelection,
    "自定义输入框残留选区时会折叠到结果末尾"
)
check(
    CaretRecoveryPolicy.action(
        currentRange: CFRange(location: 5, length: 0),
        expectedCursor: 12,
        isFinalCheckpoint: false
    ) == .stop,
    "用户主动移动到其他位置时停止光标恢复"
)
check(
    CaretRecoveryPolicy.checkpoints.last?.delay ?? 0 >= 1.3,
    "光标恢复覆盖 Electron 的延迟重置窗口"
)

do {
    let input = "开头保持，只优化这里，结尾保持"
    let expected = (input as NSString).range(of: "只优化这里")
    let resolved = try TextSelectionResolver.resolve(
        text: input,
        copiedSelection: "只优化这里",
        accessibilityRange: NSRange(location: NSMaxRange(expected), length: 0)
    )
    check(
        resolved == expected,
        "辅助功能范围错误折叠时仍根据真实选中文字局部优化"
    )
} catch {
    failures += 1
    print("FAIL  折叠选区恢复抛出异常：\(error)")
}

expectThrow("选区状态不可读时拒绝误判为全文优化") {
    _ = try TextSelectionResolver.resolve(
        text: "不能确定是否存在选区",
        copiedSelection: nil,
        accessibilityRange: nil
    )
}

do {
    let input = "微信输入框无选区"
    let resolved = try KeyboardCaptureSelectionResolver.resolve(
        text: input,
        copiedSelection: nil,
        accessibilityRange: nil
    )
    check(
        resolved == NSRange(location: (input as NSString).length, length: 0),
        "键盘回退成功读取全文后允许无选区处理"
    )
} catch {
    failures += 1
    print("FAIL  键盘回退无选区解析异常：\(error)")
}

do {
    let input = "开头保持，只优化这里，结尾保持"
    let expected = (input as NSString).range(of: "只优化这里")
    let resolved = try KeyboardCaptureSelectionResolver.resolve(
        text: input,
        copiedSelection: "只优化这里",
        accessibilityRange: nil
    )
    check(resolved == expected, "键盘回退仍优先处理真实局部选区")
} catch {
    failures += 1
    print("FAIL  键盘回退局部选区解析异常：\(error)")
}

do {
    check(OptionKeySide(keyCode: 58) == .left, "识别左 Option 键码")
    check(OptionKeySide(keyCode: 61) == .right, "识别右 Option 键码")
    check(OptionKeySide(keyCode: 59) == nil, "忽略非 Option 键码")

    var tracker = DoubleOptionSequenceTracker()
    check(
        !tracker.handleTap(side: .left, at: 1.0, maximumInterval: 1.2),
        "第一次左 Option 不触发"
    )
    check(
        tracker.handleTap(side: .left, at: 1.1, maximumInterval: 1.2),
        "间隔内第二次左 Option 触发润色"
    )
    check(
        !tracker.handleTap(side: .right, at: 3.0, maximumInterval: 1.2),
        "第一次右 Option 不触发"
    )
    check(
        tracker.handleTap(side: .right, at: 3.1, maximumInterval: 1.2),
        "间隔内第二次右 Option 触发翻译"
    )
    tracker.reset()
    check(
        !tracker.handleTap(side: .left, at: 3.2, maximumInterval: 1.2),
        "其他按键可取消 Option 连击计数"
    )
    check(
        !tracker.handleTap(side: .right, at: 3.3, maximumInterval: 1.2),
        "左右 Option 混按不会触发"
    )
    check(
        tracker.handleTap(side: .right, at: 3.4, maximumInterval: 1.2),
        "混按后第二次右 Option 可以触发"
    )
}

check(
    KeyboardFallbackPolicy.allows(bundleIdentifier: "com.openai.chat"),
    "通用回退允许普通应用"
)
check(
    KeyboardFallbackPolicy.allows(bundleIdentifier: "com.tencent.xinWeChat"),
    "通用回退保留微信支持"
)
check(
    !KeyboardFallbackPolicy.allows(bundleIdentifier: "com.apple.Terminal"),
    "键盘回退拒绝终端"
)
check(
    RewriteTargetSafetyPolicy.blockedReason(
        bundleIdentifier: "com.googlecode.iterm2"
    ) != nil,
    "触发前安全策略拒绝 iTerm"
)
check(
    RewriteTargetSafetyPolicy.allowsRewrite(
        bundleIdentifier: "com.microsoft.VSCode"
    ),
    "终端安全策略不误伤普通开发编辑器"
)
check(
    !KeyboardFallbackPolicy.allows(bundleIdentifier: "com.spacepolish.mac"),
    "通用回退排除自身"
)
check(
    KeyboardFallbackPolicy.shouldRetryCapture(
        after: .noTextToOptimize,
        bundleIdentifier: "com.tencent.xinWeChat"
    ),
    "微信辅助功能返回空文本时切换键盘回退"
)
check(
    KeyboardFallbackPolicy.shouldRetryCapture(
        after: .selectionUnavailable,
        bundleIdentifier: "com.tencent.WeWorkMac"
    ),
    "企业微信选区语义不可靠时切换键盘回退"
)
check(
    !KeyboardFallbackPolicy.shouldRetryCapture(
        after: .noTextToOptimize,
        bundleIdentifier: "com.openai.codex"
    ),
    "标准编辑器的空输入不会触发侵入式键盘读取"
)
check(
    KeyboardFallbackPolicy.shouldRetryWriteback(
        after: .readOnlyTextField,
        bundleIdentifier: "com.tencent.xinWeChat"
    ),
    "微信辅助功能值只读时允许安全键盘写回"
)
check(
    !KeyboardFallbackPolicy.shouldRetryWriteback(
        after: .textChangedWhileWaiting,
        bundleIdentifier: "com.tencent.xinWeChat"
    ),
    "等待期间文本变化时仍禁止回退覆盖"
)

check(
    PromptPolicy.resolvedPrompt(from: nil) == PromptPolicy.currentDefault,
    "首次启动使用新版默认提示词"
)
check(
    PromptPolicy.resolvedPrompt(from: PromptPolicy.legacyDefault) == PromptPolicy.currentDefault,
    "旧版默认提示词自动升级"
)
check(
    PromptPolicy.resolvedPrompt(from: PromptPolicy.previousDefault) == PromptPolicy.currentDefault,
    "上一版默认提示词自动升级"
)
check(
    PromptPolicy.resolvedPrompt(from: PromptPolicy.previousFormalDefault) == PromptPolicy.currentDefault,
    "偏正式的默认提示词自动升级"
)
check(
    PromptPolicy.resolvedPrompt(from: PromptPolicy.previousNaturalDefault) == PromptPolicy.currentDefault,
    "上一版自然口吻提示词自动升级"
)
check(
    PromptPolicy.resolvedPrompt(from: PromptPolicy.previousConservativeDefault)
        == PromptPolicy.currentDefault,
    "过度保守的默认提示词自动升级"
)
check(
    PromptPolicy.resolvedPrompt(from: "请保持简洁") == "请保持简洁",
    "保留用户自定义提示词"
)
check(
    PromptPolicy.resolvedPrompt(from: " \n ") == PromptPolicy.currentDefault,
    "空白自定义提示词回退到安全默认值"
)
check(
    PromptPolicy.polishPrompt(basePrompt: "基础规则", contextInstruction: nil)
        .contains("基础规则"),
    "没有场景规则时保留原提示词"
)
check(
    PromptPolicy.polishPrompt(basePrompt: " \n", contextInstruction: nil)
        .contains(PromptPolicy.currentDefault),
    "请求阶段不会发送空白系统提示词"
)
let chineseEditingPrompt = PromptPolicy.polishPrompt(
    basePrompt: "基础规则",
    contextInstruction: "聊天规则"
)
check(
    chineseEditingPrompt.contains("语法、搭配、语序、指代、重复")
        && chineseEditingPrompt.contains("对每个真实问题分别做最小且有效的修改")
        && chineseEditingPrompt.contains("人物、动作、对象、条件、先后关系")
        && chineseEditingPrompt.contains("只作为编辑指令，不写入成稿")
        && chineseEditingPrompt.contains("聊天规则"),
    "润色请求包含中文语法、词语搭配和原文对齐规则"
)
let noChangePolishPlan = AdaptivePolishPolicy.plan(
    for: "收到",
    applicationRole: .messaging
)
let naturalCommandPolishPlan = AdaptivePolishPolicy.plan(
    for: "字体大一点儿。",
    applicationRole: .messaging
)
let punctuatedReplyPolishPlan = AdaptivePolishPolicy.plan(
    for: "收到。",
    applicationRole: .messaging
)
check(
    noChangePolishPlan.intensity == .none
        && !noChangePolishPlan.shouldRequestModel
        && naturalCommandPolishPlan.intensity == .none
        && punctuatedReplyPolishPlan.intensity == .none,
    "自然短回复和完整短指令直接判定为无需修改"
)
let lightPolishPlan = AdaptivePolishPolicy.plan(
    for: "这个结果不对，，麻烦再检查一下",
    applicationRole: .messaging
)
check(
    lightPolishPlan.intensity == .light
        && lightPolishPlan.shouldRequestModel,
    "明确但局部的标点问题使用轻量润色"
)
let standardPolishPlan = AdaptivePolishPolicy.plan(
    for: "这个方案目前的问题是定位不够清楚，而且信息层级也比较乱，需要重新梳理一下。",
    applicationRole: .messaging
)
check(
    standardPolishPlan.intensity == .standard,
    "包含多个表达单元的普通文本使用标准润色"
)
let strongPolishPlan = AdaptivePolishPolicy.plan(
    for: "需要确认四项：规格、数量、交期、局部镀范围。",
    applicationRole: .document
)
let runOnPolishPlan = AdaptivePolishPolicy.plan(
    for: "今天和供应商讨论了材料和交期以及成本几个问题有些地方还没有确定需要他们回去确认之后再统一回复我们。",
    applicationRole: .messaging
)
check(
    strongPolishPlan.intensity == .strong
        && runOnPolishPlan.intensity == .strong,
    "明确的多项结构使用强力润色"
)
let adaptiveLightPrompt = PromptPolicy.polishPrompt(
    basePrompt: "基础规则",
    contextInstruction: "聊天规则",
    adaptivePlan: lightPolishPlan
)
check(
    adaptiveLightPrompt.contains("当前润色强度：轻量")
        && adaptiveLightPrompt.contains("不要拆句、扩写、重构")
        && adaptiveLightPrompt.contains("以本段规定的修改幅度为准"),
    "自适应强度作为末端规则约束模型修改幅度"
)
check(
    (lightPolishPlan.lengthBudget?.maximumCharacters(for: 40) ?? 0)
        < (strongPolishPlan.lengthBudget?.maximumCharacters(for: 40) ?? 0),
    "不同润色强度使用递增的长度预算"
)
let expansionPrompt = PromptPolicy.expansionPrompt(
    contextInstruction: "当前是同事聊天"
)
check(
    expansionPrompt.contains("需要“适当扩写”的原文")
        && expansionPrompt.contains("只能展开原文已有信息")
        && expansionPrompt.contains("不得为了变长加入空话")
        && expansionPrompt.contains("当前是同事聊天"),
    "适当扩写使用独立提示词并保留场景规则"
)
check(
    !PromptPolicy.polishPrompt(basePrompt: "基础规则", contextInstruction: nil)
        .contains("需要“适当扩写”的原文"),
    "适当扩写提示词不会污染普通润色"
)
check(
    RewriteLengthBudget.expansion.preferredMinimumCharacters(for: 40) == 46,
    "扩写长度预算提供可感知的最小改善目标"
)
check(
    RewriteLengthBudget.expansion.maximumCharacters(for: 40) == 80
        && RewriteLengthBudget.expansion.maximumCharacters(for: 5) == 32
        && RewriteLengthBudget.expansion.maximumCharacters(for: 500) == 660,
    "扩写长度预算同时限制比例、短文本空间和绝对增量"
)
check(
    ExpansionPolicy.shouldRequireExpansion("BOM 还没确认，等规格定了再算成本。")
        && !ExpansionPolicy.shouldRequireExpansion("好的")
        && !ExpansionPolicy.shouldRequireExpansion("这是一句已经完整清楚而且没有可展开关系的表达。"),
    "扩写策略只要求有足够信息的文本产生扩写"
)
let recentMessageTime = Date()
func recentMessage(
    _ id: String,
    _ direction: ConversationMessageDirection,
    _ text: String,
    offset: TimeInterval = 0
) -> ConversationMessage {
    ConversationMessage(
        id: id,
        conversationID: "contextual-expansion-check",
        timestamp: recentMessageTime.addingTimeInterval(offset),
        direction: direction,
        senderID: nil,
        kind: .text,
        text: text
    )
}
let analyzedRecentContext = RecentConversationAnalyzer.analyze(messages: [
    recentMessage("received-old", .received, "为什么还不能确认？", offset: -2),
    recentMessage("received-latest", .received, "这个指标什么时候能确认？", offset: -1),
    recentMessage("sent-latest", .sent, "我先看一下", offset: 0)
])
check(
    analyzedRecentContext.questionType == .timing
        && analyzedRecentContext.confidence == 0.9,
    "最近会话只从最后一条对方文本提炼问题类型"
)
let recentQuestionChecks: [(String, RecentQuestionType)] = [
    ("这个能做到吗？", .feasibility),
    ("现在进展怎么样了？", .status),
    ("为什么会这样？", .reason),
    ("这个怎么处理？", .action),
    ("规格确认了吗？", .confirmation)
]
check(
    recentQuestionChecks.allSatisfy { text, expected in
        RecentConversationAnalyzer.analyze(messages: [
            recentMessage(UUID().uuidString, .received, text)
        ]).questionType == expected
    },
    "最近会话本地识别可行性、进展、原因、处理和确认问题"
)
let contextualPolicy = CommunicationPolicy(
    intent: .inform,
    relationshipRole: .customer,
    relationshipConfidence: 0.9,
    dimensions: .defaults(for: .customer),
    voice: VoiceMetrics(),
    voiceSampleCount: 0,
    customInstruction: nil,
    messageExpansionRatio: 1.35
)
let contextualCommunicationContext = CommunicationContext(
    applicationContext: ApplicationContext(
        bundleIdentifier: "com.tencent.xinwechat",
        displayName: "微信",
        role: .messaging
    ),
    conversationSnapshot: nil,
    relationship: nil,
    intent: .inform,
    voice: VoiceProfile(),
    policy: contextualPolicy,
    dataConfidence: 0.9
)
let contextualPlan = ContextualExpansionPlanner.plan(
    sourceText: "这个指标还不能确认，需要验证后才能给结论。",
    communicationContext: contextualCommunicationContext,
    recentContext: analyzedRecentContext
)
check(
    contextualPlan.questionType == .timing
        && contextualPlan.relationshipRole == .customer
        && contextualPlan.operations.contains(.connectClauses)
        && contextualPlan.operations.contains(.clarifyReference)
        && contextualPlan.requiresVisibleExpansion,
    "上下文扩写计划组合应用、对象、问题类型与允许动作"
)
check(
    contextualPlan.modelInstruction.contains("当前对话倾向于询问时间")
        && contextualPlan.modelInstruction.contains("沟通对象类别：客户")
        && contextualPlan.modelInstruction.contains("原文没有时间信息时")
        && !contextualPlan.modelInstruction.contains("这个指标什么时候能确认"),
    "扩写提示只携带本地摘要而不携带历史消息正文"
)
let shortNoOpPlan = ContextualExpansionPlanner.plan(
    sourceText: "好的",
    communicationContext: contextualCommunicationContext,
    recentContext: analyzedRecentContext
)
check(
    !shortNoOpPlan.requiresVisibleExpansion
        && shortNoOpPlan.modelInstruction.contains("允许逐字保持原文"),
    "自然短回复在上下文扩写中仍保持安全不扩写"
)
check(
    ContextualExpansionGuard.audit(
        sourceText: "这个指标还不能确认，需要验证后才能给结论。",
        outputText: "这个指标目前还不能确认，需要完成验证后才能给出最终结论。",
        plan: contextualPlan
    ).accepted,
    "上下文扩写审查接受达到幅度且忠实整理的结果"
)
check(
    !ContextualExpansionGuard.audit(
        sourceText: "这个指标还不能确认，需要验证后才能给结论。",
        outputText: "这个指标还不能确认，需要验证。",
        plan: contextualPlan
    ).accepted,
    "上下文扩写审查拒绝只有等长整理的候选"
)
let recentCacheCheck = waitForAsync {
    let cache = RecentContextCache(lifetime: 120)
    let now = Date()
    let context = RecentConversationContext(questionType: .status, confidence: 0.9)
    await cache.save(context, for: "wechat|customer", now: now)
    let live = await cache.context(
        for: "wechat|customer",
        now: now.addingTimeInterval(60)
    )
    let expired = await cache.context(
        for: "wechat|customer",
        now: now.addingTimeInterval(121)
    )
    return live == context && expired == nil
}
check(
    (try? recentCacheCheck.get()) == true,
    "最近会话摘要缓存两分钟并在过期后清除"
)
let numberedParallelText = "需要确认以下四项：\n1、规格\n2、数量\n3、交期\n4、局部镀范围"
check(
    ParallelListPolicy.shouldPreferNumberedList(
        "这次需要确认四项：规格、数量、交期、局部镀范围。"
    )
        && ParallelListPolicy.containsNumberedList(numberedParallelText),
    "明确的三项以上并列内容会识别为编号列表"
)
check(
    !ParallelListPolicy.shouldPreferNumberedList(
        "BOM 还没确认，等规格定了再算成本。"
    ),
    "普通连续分句不会被误识别为编号列表"
)
check(
    PromptPolicy.currentDefault.contains("结论和确定程度")
        && PromptPolicy.currentDefault.contains("不是邮件、工作汇报、会议纪要、客服话术")
        && PromptPolicy.currentDefault.contains("保持原文的亲疏程度、直接程度和自然省略")
        && PromptPolicy.currentDefault.contains("讨论了下")
        && PromptPolicy.currentDefault.contains("BOM 里局部镀")
        && PromptPolicy.currentDefault.contains("发现多个问题时全部处理")
        && PromptPolicy.currentDefault.contains("有明确改进空间时必须给出真正改善后的版本")
        && PromptPolicy.currentDefault.contains("才可以原样返回")
        && !PromptPolicy.currentDefault.contains("优先原样输出"),
    "新版提示词兼顾信息保留和主动有效修改"
)
let opticsSemanticMatches = SemanticLibraryCatalog.matches(
    in: "780 nm 激光经过准直后，光斑直径和 M² 都需要复测。"
)
check(
    opticsSemanticMatches.first?.id == .opticsAndLaser,
    "光学术语会命中光学与激光语义库"
)
let manufacturingSemanticMatches = SemanticLibraryCatalog.matches(
    in: "BOM 还在备料，CAPA 关闭前不要转量产。"
)
check(
    manufacturingSemanticMatches.contains(where: { $0.id == .manufacturingAndQuality }),
    "BOM、备料和 CAPA 会命中制造与质量语义库"
)
let embeddedSemanticMatches = SemanticLibraryCatalog.matches(
    in: "新的 I2C 驱动不稳定，上电后 SDA 引脚会导致通信中断。"
)
check(
    embeddedSemanticMatches.first?.id == .embeddedHardware,
    "I2C、SDA、上电和通信中断会命中嵌入式语义库"
)
let embeddedInstruction = SemanticLibraryCatalog.modelInstruction(
    for: "测试 I2C 模块时，加电后 SDA 通讯中断。"
) ?? ""
check(
    embeddedInstruction.contains("嵌入式与硬件")
        && embeddedInstruction.contains("上电")
        && embeddedInstruction.contains("通讯")
        && embeddedInstruction.contains("通信会突然中断")
        && embeddedInstruction.contains("通信中断与硬件中断"),
    "嵌入式语义库提供领域术语和歧义保护"
)
check(
    SemanticLibraryCatalog.matches(in: "项目").isEmpty,
    "单个宽泛词不会误触发项目语义库"
)
check(
    SemanticLibraryCatalog.matches(
        in: "这个 API 的 JSON 返回值需要调整。",
        enabled: [.opticsAndLaser]
    ).isEmpty,
    "关闭的软件开发语义库不会参与匹配"
)
check(
    SemanticLibraryCatalog.matches(in: "capability").isEmpty,
    "英文缩写按完整词匹配，避免 API 子串误判"
)
let mixedSemanticInstruction = SemanticLibraryCatalog.modelInstruction(
    for: "激光 BOM 交期 报价 API"
) ?? ""
check(
    mixedSemanticInstruction.contains("光学与激光")
        && mixedSemanticInstruction.contains("制造与质量")
        && mixedSemanticInstruction.contains("项目与交付")
        && !mixedSemanticInstruction.contains("软件开发"),
    "一次最多注入三个最相关语义库，控制提示词长度"
)
check(
    SemanticLibraryCatalog.protectedTerms(in: "请确认 BOM、M² 和 NA=0.22")
        == ["M²", "NA", "BOM"],
    "高风险专业缩写会进入本地受保护内容"
)
check(
    SemanticLibraryCatalog.protectedTerms(
        in: "请确认 API 返回的 JSON",
        enabled: [.opticsAndLaser]
    ).isEmpty,
    "关闭语义库后不再添加该库的受保护术语"
)
let semanticDefaultsName = "PoleChecks.SemanticLibraries.\(UUID().uuidString)"
if let semanticDefaults = UserDefaults(suiteName: semanticDefaultsName) {
    semanticDefaults.removePersistentDomain(forName: semanticDefaultsName)
    check(
        SemanticLibraryPreferences.load(from: semanticDefaults)
            == SemanticLibraryID.defaultEnabled,
        "首次使用时默认启用全部内置语义库"
    )
    SemanticLibraryPreferences.save([.opticsAndLaser, .softwareDevelopment], to: semanticDefaults)
    check(
        SemanticLibraryPreferences.load(from: semanticDefaults)
            == [.opticsAndLaser, .softwareDevelopment],
        "语义库开关可以持久化"
    )
    semanticDefaults.set(
        [SemanticLibraryID.opticsAndLaser.rawValue],
        forKey: SemanticLibraryPreferences.defaultsKey
    )
    semanticDefaults.removeObject(forKey: "semanticLibraryCatalogVersion")
    check(
        SemanticLibraryPreferences.load(from: semanticDefaults)
            == [.opticsAndLaser, .embeddedHardware],
        "升级后默认启用新增的嵌入式语义库，同时保留原有开关"
    )
    semanticDefaults.removePersistentDomain(forName: semanticDefaultsName)
}
check(
    TranslationPolicy.prompt.contains("主要是中文")
        && TranslationPolicy.prompt.contains("简体中文")
        && TranslationPolicy.prompt.contains("只输出翻译结果"),
    "翻译规则支持中译英和外语译中"
)
do {
    let response = "保留缩进"
    let preparedResponse = try RewriteResultPolicy.prepare(
        response,
        preservingBoundaryWhitespaceOf: "  原文\n"
    )
    check(
        preparedResponse == "  保留缩进\n",
        "模型结果继承原文首尾空白和换行"
    )
} catch {
    failures += 1
    print("FAIL  模型结果格式校验抛出异常：\(error)")
}
do {
    let preparedResponse = try RewriteResultPolicy.prepare(
        " \n模型结果\n ",
        preservingBoundaryWhitespaceOf: "原文"
    )
    check(preparedResponse == "模型结果", "模型结果移除额外的首尾空白")
} catch {
    failures += 1
    print("FAIL  模型结果边界清理抛出异常：\(error)")
}
do {
    let response = """
    俞博，新的 I2C 驱动不太稳定。下午测试了几台模块，上电过程中通信会突然中断，之后持续报错。初步怀疑 SDA 引脚存在故障，板子已经寄给明义微进一步排查。

    优化说明：
    1. 将“通讯”改为“通信”。
    2. 调整语序。
    """
    let preparedResponse = try RewriteResultPolicy.prepare(
        response,
        preservingBoundaryWhitespaceOf: "俞博，新的 I2C 驱动不太稳定。"
    )
    check(
        preparedResponse == "俞博，新的 I2C 驱动不太稳定。下午测试了几台模块，上电过程中通信会突然中断，之后持续报错。初步怀疑 SDA 引脚存在故障，板子已经寄给明义微进一步排查。",
        "模型附加的优化说明不会写回输入框"
    )
} catch {
    failures += 1
    print("FAIL  优化说明清理抛出异常：\(error)")
}
do {
    let preparedResponse = try RewriteResultPolicy.prepare(
        "优化后的文本：上电过程中通信会突然中断。",
        preservingBoundaryWhitespaceOf: "加电过程中会突然通讯中断。"
    )
    check(preparedResponse == "上电过程中通信会突然中断。", "模型结果标题不会写回输入框")
} catch {
    failures += 1
    print("FAIL  模型结果标题清理抛出异常：\(error)")
}
do {
    let source = "优化说明：请保留 I2C 和 SDA。"
    let preparedResponse = try RewriteResultPolicy.prepare(
        source,
        preservingBoundaryWhitespaceOf: source
    )
    check(preparedResponse == source, "原文本身的优化说明标题不会被误删")
} catch {
    failures += 1
    print("FAIL  合法说明标题保护抛出异常：\(error)")
}
do {
    let preparedResponse = try RewriteResultPolicy.prepare(
        "正文逻辑有点乱，前后说法也不一致，怎么优化？",
        preservingBoundaryWhitespaceOf: "正文里面的逻辑有点乱，而且前后说法不一致。怎么优化？"
    )
    check(
        preparedResponse == "正文逻辑有点乱，前后说法也不一致。",
        "面向编辑器的尾部润色要求不会写回成稿"
    )
} catch {
    failures += 1
    print("FAIL  尾部润色要求清理抛出异常：\(error)")
}
do {
    let source = "我们正在讨论这段文案怎么优化？"
    let preparedResponse = try RewriteResultPolicy.prepare(
        source,
        preservingBoundaryWhitespaceOf: source
    )
    check(preparedResponse == source, "讨论编辑工作的正文不会被误删")
} catch {
    failures += 1
    print("FAIL  编辑讨论正文保护抛出异常：\(error)")
}
expectThrow("模型结果拒绝纯空白内容") {
    _ = try RewriteResultPolicy.prepare(
        " \n\t",
        preservingBoundaryWhitespaceOf: "原文"
    )
}
check(
    OptimizationOutcome.classify(sourceText: "无需改动", result: "无需改动")
        == .unchanged,
    "相同结果归类为无需修改"
)
check(
    OptimizationOutcome.classify(
        sourceText: "同样的内容\r\n第二行",
        result: "同样的\u{200B}内容\n第二行"
    ) == .unchanged,
    "只有换行编码或零宽占位差异时归类为无需修改"
)
check(
    OptimizationOutcome.classify(
        sourceText: "规格 A",
        result: "规格\u{00A0}A"
    ) == .unchanged,
    "普通空格与不换行空格的视觉等价结果归类为无需修改"
)
check(
    OptimizationOutcome.classify(sourceText: "规格 A", result: "规格A")
        != .unchanged,
    "真实可见的空格删除仍归类为修改"
)
check(
    OptimizationOutcome.classify(
        sourceText: "这句话有一点不通顺",
        result: "这句话有一点不够通顺"
    ) == .partial,
    "小范围修改归类为有效优化"
)
check(
    OptimizationOutcome.classify(
        sourceText: "这个写得不好",
        result: "请重新整理这段表达，使其更清晰自然"
    ) == .complete,
    "明显改写归类为完整优化"
)
check(
    InputProgressSoundCue.result(
        for: .complete,
        operation: .optimization
    ) == .completion,
    "完成优化使用确认音"
)
check(
    InputProgressSoundCue.result(
        for: .unchanged,
        operation: .optimization
    ) == .unchanged,
    "无需修改使用轻提示音"
)
check(
    InputProgressSoundCue.result(
        for: .unchanged,
        operation: .translation
    ) == .unchanged,
    "翻译结果未变化时也使用无需修改提示音"
)
check(
    InputProgressSoundCue.completion.resourceName == "uisfx-minimal-complete",
    "完成态使用 UI SFX Minimal 的流程完成音效"
)
check(
    InputProgressSoundCue.completion.fallbackSoundName == "Glass",
    "完成音效资源缺失时回退到系统 Glass"
)
let completionColor = InputProgressPalette.completion
check(
    completionColor.redComponent < 0.10
        && completionColor.greenComponent > 0.50
        && completionColor.greenComponent < 0.56
        && completionColor.blueComponent > 0.25
        && completionColor.blueComponent < 0.30
        && completionColor.alphaComponent == 1,
    "完成勾选使用白底清晰的深绿色"
)
check(
    QwenClient.requestTimeout(for: "短消息", isRetry: false) == 20,
    "短消息首轮请求使用较短超时"
)
check(
    QwenClient.requestTimeout(for: "短消息", isRetry: true) >= 12
        && QwenClient.requestTimeout(for: "短消息", isRetry: true) < 20,
    "短消息纠错重试不会再次等待完整首轮超时"
)
check(
    QwenClient.requestTimeout(
        for: String(repeating: "长", count: 1_500),
        isRetry: false
    ) == 45,
    "长文本保留完整请求超时"
)
check(
    InputProgressMotionPolicy.style(
        from: CGPoint(x: 100, y: 100),
        to: CGPoint(x: 124, y: 102),
        reducesMotion: false
    ) == .eased,
    "同行小范围光标移动使用缓动"
)
check(
    InputProgressMotionPolicy.style(
        from: CGPoint(x: 100, y: 100),
        to: CGPoint(x: 112, y: 118),
        reducesMotion: false
    ) == .crossfade,
    "跨行光标移动使用交叉淡化"
)
check(
    InputProgressMotionPolicy.style(
        from: CGPoint(x: 100, y: 100),
        to: CGPoint(x: 180, y: 100),
        reducesMotion: false
    ) == .crossfade,
    "长距离光标移动使用交叉淡化"
)
check(
    InputProgressMotionPolicy.style(
        from: CGPoint(x: 100, y: 100),
        to: CGPoint(x: 124, y: 102),
        reducesMotion: true
    ) == .immediate,
    "减少动态效果时直接定位"
)
check(QwenClient.temperature == 0.5, "模型温度保持为 0.5")
check(QwenClient.defaultModel == "qwen3.7-plus", "默认使用 Qwen 3.7 Plus")
check(!QwenClient.enableThinking, "Qwen 关闭思考模式")

let codexApplicationContext = ApplicationContextClassifier.context(
    bundleIdentifier: "com.openai.codex",
    localizedName: "Codex"
)
check(codexApplicationContext.role == .aiDevelopmentAssistant, "Codex 自动识别为 AI 开发助手")
check(!codexApplicationContext.supportsConversationProfiles, "Codex 不进入聊天对象识别")

let chatGPTApplicationContext = ApplicationContextClassifier.context(
    bundleIdentifier: "com.openai.chat",
    localizedName: "ChatGPT"
)
check(chatGPTApplicationContext.role == .aiAssistant, "ChatGPT 自动识别为 AI 助手")

let messagingApplicationContext = ApplicationContextClassifier.context(
    bundleIdentifier: "com.tencent.xinWeChat",
    localizedName: "微信"
)
check(messagingApplicationContext.supportsConversationProfiles, "聊天客户端继续识别具体会话")

check(
    ApplicationContextClassifier.context(
        bundleIdentifier: "com.apple.dt.Xcode",
        localizedName: "Xcode"
    ).role == .development,
    "开发工具自动使用开发编辑规则"
)
check(
    ApplicationContextClassifier.context(
        bundleIdentifier: "com.apple.mail",
        localizedName: "邮件"
    ).role == .email,
    "邮件应用自动使用邮件沟通规则"
)
check(
    ApplicationContextClassifier.context(
        bundleIdentifier: "com.example.unknown",
        localizedName: "未知应用"
    ).role == .generic,
    "未知应用降级为通用润色"
)

let codexContextInstruction = ApplicationContextPolicy.contextInstruction(
    for: codexApplicationContext,
    conversationInstruction: "把内容写成给上级的汇报"
)
check(
    codexContextInstruction?.contains("AI 开发助手") == true
        && codexContextInstruction?.contains("给上级的汇报") == false,
    "Codex 应用规则覆盖误设的聊天对象角色"
)
let codexPrompt = PromptPolicy.polishPrompt(
    basePrompt: "基础规则",
    contextInstruction: codexContextInstruction
)
check(codexPrompt.contains("AI 开发助手"), "Codex 场景规则会进入润色提示词")
check(
    !codexPrompt.contains("Codex") && !codexPrompt.contains("com.openai.codex"),
    "应用名称和 Bundle ID 不会进入请求提示词"
)
check(
    ApplicationContextPolicy.contextInstruction(
        for: messagingApplicationContext,
        conversationInstruction: "给客户的消息保持礼貌"
    )?.contains("给客户的消息保持礼貌") == true,
    "聊天客户端保留当前对象规则"
)
check(
    ApplicationContextPolicy.contextInstruction(
        for: messagingApplicationContext,
        conversationInstruction: nil
    ).map {
        $0.contains("礼貌不等于正式")
            && $0.contains("有明确提升空间时至少完成一处有效修改")
            && !$0.contains("只调整确实影响理解或流畅度的部分")
    } == true,
    "聊天客户端使用主动且自然的即时消息规则"
)
let messagingPrompt = PromptPolicy.polishPrompt(
    basePrompt: "基础规则",
    contextInstruction: ApplicationContextPolicy.contextInstruction(
        for: messagingApplicationContext,
        conversationInstruction: ConversationRole.customer.defaultInstruction
    )
)
check(
    messagingPrompt.contains("自然省略")
        && messagingPrompt.contains("不要改成客服、邮件或公文语气"),
    "客户礼貌规则不会把微信改成正式话术"
)
check(!TranslationPolicy.prompt.contains("AI 开发助手"), "翻译提示词不携带应用场景规则")

let neutralCommunicationPolicy = CommunicationPolicy(
    intent: .unknown,
    relationshipRole: nil,
    relationshipConfidence: 0,
    dimensions: nil,
    voice: VoiceMetrics(),
    voiceSampleCount: 0,
    customInstruction: nil,
    messageExpansionRatio: 1.35
)
check(
    neutralCommunicationPolicy.modelInstruction.contains("只决定沟通口吻和组织方式")
        && neutralCommunicationPolicy.modelInstruction.contains("不能覆盖事实保护边界")
        && neutralCommunicationPolicy.modelInstruction.contains("礼貌不等于正式")
        && !neutralCommunicationPolicy.modelInstruction.contains("只有原文已经自然准确时才保持不变"),
    "沟通策略只提供风格上下文，不重复基础编辑规则"
)

let learnedCommunicationPolicy = CommunicationPolicy(
    intent: .casual,
    relationshipRole: nil,
    relationshipConfidence: 0,
    dimensions: nil,
    voice: VoiceMetrics(
        averageSentenceLength: 10,
        emojiRate: 0,
        exclamationRate: 0,
        formality: 0.25,
        directness: 0.78,
        detail: 0.35,
        styleMarkers: ["哈哈", "行"]
    ),
    voiceSampleCount: 8,
    customInstruction: nil,
    messageExpansionRatio: 1.35
)
check(
    learnedCommunicationPolicy.modelInstruction.contains("本地个人画像摘要")
        && learnedCommunicationPolicy.modelInstruction.contains("不复用历史中的事实"),
    "个人画像以不含历史正文的风格摘要进入提示词"
)

check(
    ConversationTitleNormalizer.normalize("  张  总\n") == "张 总",
    "会话标题会去除首尾和重复空白"
)
check(
    !ConversationTitleNormalizer.isUsable("微信", applicationName: "微信"),
    "应用通用标题不能作为聊天对象"
)
check(
    !ConversationTitleNormalizer.isUsable("21:10", applicationName: "微信"),
    "侧栏时间不能作为聊天对象"
)
check(
    !ConversationTitleNormalizer.isUsable("晚上 9:10", applicationName: "微信"),
    "带时段的时间不能作为聊天对象"
)
check(
    !ConversationTitleNormalizer.isUsable("7月22日 21:10", applicationName: "微信"),
    "日期时间不能作为聊天对象"
)
check(
    !ConversationTitleNormalizer.isUsable("星期一", applicationName: "微信"),
    "侧栏星期不能作为聊天对象"
)
check(
    ConversationTitleNormalizer.isUsable("老婆", applicationName: "微信"),
    "明确联系人标题保持可用"
)
check(
    ConversationRoleInference.infer(from: "老婆") == .friendOrFamily,
    "老婆会自动识别为朋友或家人"
)
check(
    ConversationRoleInference.infer(from: "❤️ 老婆 ❤️") == .friendOrFamily,
    "带装饰符号的明确亲密称谓仍能自动识别"
)
check(
    ConversationRoleInference.infer(from: "王总（客户）") == .customer,
    "联系人备注中的明确客户标签会自动识别"
)
check(
    ConversationRoleInference.infer(from: "老板 - 李总") == .manager,
    "联系人备注中的明确上级标签会自动识别"
)
check(
    ConversationRoleInference.infer(from: "同事群") == .colleague,
    "明确同事群标题会自动识别为同事场景"
)
check(
    ConversationRoleInference.infer(from: "项目群") == nil,
    "可能包含客户的项目群不会自动猜测关系"
)
check(
    ConversationRoleInference.infer(from: "老婆饼店") == nil,
    "称谓只按完整语义片段匹配，避免子串误判"
)
check(
    ConversationRoleInference.infer(from: "张总") == nil,
    "可能是上级或客户的模糊称谓仍需人工确认"
)
check(
    ConversationRoleInference.infer(from: "老婆（客户）") == nil,
    "标题同时包含冲突角色时不会自动猜测"
)

let accessibilityCandidate = ConversationTitleCandidate(
    title: "张总",
    source: .accessibilityHeader,
    confidence: 0.91
)
let ocrCandidate = ConversationTitleCandidate(
    title: "OCR 误读",
    source: .ocr,
    confidence: 0.99
)
check(
    ConversationCandidateSelector.bestCandidate(
        [ocrCandidate, accessibilityCandidate],
        applicationName: "微信"
    ) == accessibilityCandidate,
    "辅助功能标题优先于 OCR 结果"
)
let uncertainAccessibilityCandidate = ConversationTitleCandidate(
    title: "不完整标题",
    source: .accessibilityHeader,
    confidence: 0.64
)
check(
    ConversationCandidateSelector.preferredCandidate(
        accessibilityCandidate: uncertainAccessibilityCandidate,
        ocrCandidate: ocrCandidate
    ) == ocrCandidate,
    "低置信度辅助功能标题会让高置信度 OCR 兜底"
)

let conversationSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: 12,
    candidate: accessibilityCandidate
)
check(conversationSnapshot.canCreateProfile, "高置信度会话可以创建对象规则")

let lowConfidenceSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: 12,
    candidate: ConversationTitleCandidate(title: "不确定对象", source: .ocr, confidence: 0.6)
)
check(!lowConfidenceSnapshot.canCreateProfile, "低置信度 OCR 不会自动绑定对象")

let codexWindowSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.openai.codex",
    processIdentifier: 44,
    windowIdentifier: 14,
    candidate: ConversationTitleCandidate(
        title: "Checks/main.swift",
        source: .windowTitle,
        confidence: 0.96
    )
)
check(!codexWindowSnapshot.canCreateProfile, "Codex 文件标题不会被绑定为聊天对象")

let contextSuiteName = "PoleConversationChecks-\(UUID().uuidString)"
let contextDefaults = UserDefaults(suiteName: contextSuiteName)!
contextDefaults.removePersistentDomain(forName: contextSuiteName)
let conversationStore = ConversationProfileStore(defaults: contextDefaults)
let wifeSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: 12,
    candidate: ConversationTitleCandidate(
        title: "老婆",
        source: .accessibilityHeader,
        confidence: 0.94
    )
)
let inferredWifeProfile = conversationStore.createInferredProfile(for: wifeSnapshot)
check(
    inferredWifeProfile?.role == .friendOrFamily,
    "明确称谓会直接创建可编辑的本地角色档案"
)
if let inferredWifeProfile {
    conversationStore.delete(id: inferredWifeProfile.id)
}
let createdProfile = conversationStore.createProfile(
    for: conversationSnapshot,
    role: .customer,
    customInstruction: "给张总的消息要礼貌、简洁。"
)
check(createdProfile != nil, "高置信度会话可以保存个人规则")
check(
    conversationStore.profile(for: conversationSnapshot)?.role == .customer,
    "已保存对象规则能自动匹配原会话"
)
let otherApplicationSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.WeWorkMac",
    processIdentifier: 43,
    windowIdentifier: 13,
    candidate: accessibilityCandidate
)
check(
    conversationStore.profile(for: otherApplicationSnapshot) == nil,
    "相同名称在不同聊天应用不会串用规则"
)
check(
    conversationStore.createProfile(
        for: lowConfidenceSnapshot,
        role: .colleague,
        customInstruction: "不应保存"
    ) == nil,
    "低置信度会话不会写入本地对象档案"
)

if let createdProfile {
    let composedPrompt = PromptPolicy.polishPrompt(
        basePrompt: "基础规则",
        contextInstruction: createdProfile.modelInstruction
    )
    check(composedPrompt.contains("礼貌、简洁"), "个人规则会追加到润色提示词")
    check(!composedPrompt.contains("张总"), "会话名称不会进入润色提示词")
    check(!TranslationPolicy.prompt.contains("礼貌、简洁"), "翻译提示词不携带对象规则")

    let spacedNameProfile = ConversationProfile(
        applicationIdentifier: "com.tencent.xinWeChat",
        conversationTitle: "张 总",
        role: .custom,
        customInstruction: "给张总的内容要自然。"
    )
    check(!spacedNameProfile.modelInstruction.contains("张总"), "规则中的紧凑会话名称也会在发送前移除")

    let legacyManagerProfile = ConversationProfile(
        applicationIdentifier: "com.tencent.xinWeChat",
        conversationTitle: "旧预设",
        role: .manager,
        customInstruction: "语气尊重、简洁，优先交代结论、进度或明确问题；保留原文的确定程度，不增加承诺或解释。"
    )
    check(
        legacyManagerProfile.customInstruction == ConversationRole.manager.defaultInstruction
            && legacyManagerProfile.modelInstruction.contains("自然的聊天口吻"),
        "旧聊天对象预设自动迁移为自然口吻"
    )

    let previousFamilyProfile = ConversationProfile(
        applicationIdentifier: "com.tencent.xinWeChat",
        conversationTitle: "老婆",
        role: .friendOrFamily,
        customInstruction: "保持本人日常聊天的口吻和亲疏程度，自然、亲切即可；不要刻意热情、卖萌、解释或添加客套话。"
    )
    check(
        previousFamilyProfile.customInstruction == ConversationRole.friendOrFamily.defaultInstruction
            && previousFamilyProfile.modelInstruction.contains("不要为了缩短而删成命令清单")
            && previousFamilyProfile.modelInstruction.contains("原文没有句号时不要强行补句号"),
        "上一版朋友家人规则自动迁移为最小改写规则"
    )

    conversationStore.update(
        id: createdProfile.id,
        role: .manager,
        customInstruction: "表达简洁，先说明结论。"
    )
    let reloadedStore = ConversationProfileStore(defaults: contextDefaults)
    check(
        reloadedStore.profile(for: conversationSnapshot)?.role == .manager,
        "对象规则会持久化到本地设置"
    )
    conversationStore.delete(id: createdProfile.id)
    check(conversationStore.profiles.isEmpty, "对象规则可以删除")
}
contextDefaults.removePersistentDomain(forName: contextSuiteName)

let sameConversationSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: 12,
    candidate: accessibilityCandidate
)
let switchedTitleSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: 12,
    candidate: ConversationTitleCandidate(title: "项目群", source: .windowTitle, confidence: 0.96)
)
let switchedWindowSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: 18,
    candidate: accessibilityCandidate
)
let missingWindowSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: nil,
    candidate: accessibilityCandidate
)
check(conversationSnapshot.matches(sameConversationSnapshot), "相同聊天快照允许安全写回")
check(!conversationSnapshot.matches(switchedTitleSnapshot), "会话标题变化会拒绝写回")
check(!conversationSnapshot.matches(switchedWindowSnapshot), "窗口变化会拒绝写回")
check(!conversationSnapshot.matches(missingWindowSnapshot), "窗口标识丢失会拒绝写回")

let ocrConversationSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: 12,
    candidate: ConversationTitleCandidate(title: "张总", source: .ocr, confidence: 0.96)
)
let lightweightSameWindowSnapshot = ConversationSnapshot(
    applicationIdentifier: "com.tencent.xinWeChat",
    processIdentifier: 42,
    windowIdentifier: 12,
    candidate: nil
)
check(
    !ConversationResolutionMode.writebackValidation.usesOCR,
    "写回前轻量校验不再重复 OCR"
)
check(
    ocrConversationSnapshot.matchesForWriteback(lightweightSameWindowSnapshot),
    "OCR 会话可用应用和窗口完成轻量写回校验"
)
check(
    !ocrConversationSnapshot.matchesForWriteback(switchedTitleSnapshot),
    "轻量校验发现可访问标题变化时仍拒绝写回"
)
check(
    !ocrConversationSnapshot.matchesForWriteback(switchedWindowSnapshot),
    "轻量校验发现窗口变化时仍拒绝写回"
)

let managerMessages = [
    ConversationMessage(id: "1", conversationID: "c1", timestamp: Date(), direction: .received, senderID: "other", kind: .text, text: "这个项目什么时候完成？尽快再看一下"),
    ConversationMessage(id: "2", conversationID: "c1", timestamp: Date(), direction: .sent, senderID: "self", kind: .text, text: "收到，我调整后同步进展"),
    ConversationMessage(id: "3", conversationID: "c1", timestamp: Date(), direction: .received, senderID: "other", kind: .text, text: "方案改一下，明天汇报"),
    ConversationMessage(id: "4", conversationID: "c1", timestamp: Date(), direction: .sent, senderID: "self", kind: .text, text: "好的，我先确认需求和排期"),
    ConversationMessage(id: "5", conversationID: "c1", timestamp: Date(), direction: .sent, senderID: "self", kind: .text, text: "收到，我同步一下项目进度")
]
let managerAnalysis = RelationshipAnalyzer.analyze(title: "直属领导", messages: managerMessages)
check(managerAnalysis.role == .manager, "历史互动与明确称谓可识别上级关系")
check(managerAnalysis.confidence >= 0.70, "充分关系证据达到自动绑定阈值")

let friendMessages = (0..<6).map {
    ConversationMessage(
        id: "f\($0)",
        conversationID: "friend",
        timestamp: Date(),
        direction: $0.isMultiple(of: 2) ? .sent : .received,
        senderID: nil,
        kind: .text,
        text: $0.isMultiple(of: 2) ? "哈哈可以，周末一起吃饭😂" : "笑死，晚安啦🤣"
    )
}
check(
    RelationshipAnalyzer.analyze(title: "老婆", messages: friendMessages).role == .friendOrFamily,
    "亲密称谓与休闲互动可识别朋友家人关系"
)

let learnedVoice = VoiceAnalyzer.metrics(from: ["收到，我先确认一下", "可以，我这边推进", "好的，稍后同步"])
check(learnedVoice.styleMarkers.contains("同步") || learnedVoice.styleMarkers.contains("确认"), "声音画像只提取允许的语气标记")
check(!learnedVoice.styleMarkers.contains("项目"), "声音画像不把内容名词当作风格")
check(CommunicationIntentAnalyzer.infer(from: "麻烦帮我确认一下") == .request, "本地意图识别可识别请求")
check(CommunicationIntentAnalyzer.infer(from: "抱歉，这次没有处理好") == .apologize, "本地意图识别可识别道歉")

let fingerprintSample = PendingRewriteSample(
    relationshipID: nil,
    conversationID: "opaque",
    rewrittenText: "这是只用于匹配的成稿内容"
)
if let encodedFingerprint = try? JSONEncoder().encode(fingerprintSample) {
    check(
        !String(decoding: encodedFingerprint, as: UTF8.self).contains("这是只用于匹配的成稿内容"),
        "待匹配成稿只保存指纹而不保存正文"
    )
} else {
    check(false, "待匹配成稿指纹可以编码")
}

let learnedHistoryMetrics = RewriteHistoryPolicy.learnedMetrics(
    sourceText: "哈哈，行，我再看一下",
    rewrittenText: "行，我再看一下。"
)
check(
    learnedHistoryMetrics.styleMarkers.contains("哈哈") || learnedHistoryMetrics.styleMarkers.contains("行"),
    "优化历史画像优先保留用户原稿的稳定语气"
)

let historyNow = Date()
let retainedHistory = RewriteHistoryPolicy.retained(
    (0..<205).map { index in
        RewriteHistoryEntry(
            sourceText: "原文\(index)",
            rewrittenText: "结果\(index)",
            applicationRole: .messaging,
            relationshipID: nil,
            createdAt: historyNow.addingTimeInterval(TimeInterval(index))
        )
    },
    now: historyNow.addingTimeInterval(205)
)
check(retainedHistory.count == 200, "优化历史最多保留 200 条")

let safeRewrite = StructuredRewriteResult(
    rewrittenText: "项目可能延期两周，因为供应商接口还没完成。",
    intent: .inform,
    preservedClaims: ["可能延期两周", "供应商接口未完成"]
)
check(
    FactGuard.audit(
        sourceText: "项目可能延期两周，因为供应商接口还没完成。",
        result: safeRewrite,
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫接受忠实的小范围优化"
)
let certaintyRewrite = StructuredRewriteResult(
    rewrittenText: "项目已经延期两周，因为供应商接口还没完成。",
    intent: .inform,
    preservedClaims: [],
    certaintyChanges: ["可能改成已经"]
)
check(
    !FactGuard.audit(
        sourceText: "项目可能延期两周，因为供应商接口还没完成。",
        result: certaintyRewrite,
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫拒绝把可能改成已经"
)
let inventedRewrite = StructuredRewriteResult(
    rewrittenText: "项目可能延期两周，我们会在周五完成备用方案。",
    addedClaims: ["周五完成备用方案"]
)
check(
    !FactGuard.audit(
        sourceText: "项目可能延期两周。",
        result: inventedRewrite,
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫拒绝新增时间和行动承诺"
)
check(
    !FactGuard.audit(
        sourceText: "项目可能延期。",
        result: StructuredRewriteResult(rewrittenText: "项目可能延期，因为供应商没有交付。"),
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫不依赖模型自报也会拒绝新增原因"
)
check(
    !FactGuard.audit(
        sourceText: "先把报价发送给客户，再确认合同。",
        result: StructuredRewriteResult(rewrittenText: "确认合同。"),
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫拒绝删除对象、动作和先后关系"
)
check(
    !FactGuard.audit(
        sourceText: "这个问题还需要处理。",
        result: StructuredRewriteResult(rewrittenText: "这个问题交给小王负责处理。"),
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫拒绝擅自增加责任人"
)
check(
    FactGuard.audit(
        sourceText: "项目可能延期两周。",
        result: StructuredRewriteResult(
            rewrittenText: "项目可能延期两周。",
            addedClaims: ["模型认为这句话包含新增事实"],
            certaintyChanges: ["模型认为确定程度发生变化"]
        ),
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫不把模型自报字段当作硬拒绝依据"
)
check(
    FactGuard.audit(
        sourceText: "你先把材料发给客户，然后再回复我",
        result: StructuredRewriteResult(rewrittenText: "材料给客户发过去后再回我一下"),
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫接受保留动作和先后关系的自然聊天改写"
)
check(
    !FactGuard.audit(
        sourceText: "帮我拿瓶可乐打开，再拿个小蛋糕给我吃",
        result: StructuredRewriteResult(rewrittenText: "帮我拿瓶可乐打开，再拿个小蛋糕"),
        applicationRole: .messaging,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫拒绝删除吃喝等日常关键动作"
)
check(
    !MessagingRewriteRetryPolicy.shouldRetryUnchanged(
        sourceText: "这个方案我再看看",
        candidate: "这个方案我再看看"
    ),
    "自然完整的短消息不为制造变化而重试"
)
check(
    !MessagingRewriteRetryPolicy.shouldRetryUnchanged(
        sourceText: "好的",
        candidate: "好的"
    ),
    "自然短回复不为制造变化而重复请求"
)
check(
    MessagingRewriteRetryPolicy.shouldRetryUnchanged(
        sourceText: "这个结果不对，，麻烦再检查一下！！",
        candidate: "这个结果不对，，麻烦再检查一下！！"
    ),
    "原样候选没有处理明确标点问题时会重试"
)
check(
    !RewriteQualityGuard.audit(
        sourceText: "这个问题我再确认一下。",
        outputText: "现将该问题的确认情况同步如下。",
        applicationRole: .messaging
    ).accepted,
    "质量门拒绝把聊天改成工作汇报"
)
check(
    !RewriteQualityGuard.audit(
        sourceText: "正文逻辑有点乱。怎么优化？",
        outputText: "正文的逻辑有些乱，怎么优化？",
        applicationRole: .messaging
    ).accepted,
    "质量门拒绝把面向编辑器的要求留在成稿中"
)
check(
    RewriteQualityGuard.audit(
        sourceText: "这个方案我再看看",
        outputText: "这个方案我再看看",
        applicationRole: .messaging
    ).accepted,
    "质量门允许已经自然的短消息保持不变"
)
check(
    !RewriteQualityGuard.audit(
        sourceText: "BOM 还没确认，等规格定了再算成本。",
        outputText: "BOM 还没确认，等规格定了再算成本。",
        applicationRole: .messaging,
        rewriteMode: .expand,
        lengthBudget: .expansion
    ).accepted,
    "扩写质量门拒绝对可扩写文本原样返回"
)
check(
    RewriteQualityGuard.audit(
        sourceText: "BOM 还没确认，等规格定了再算成本。",
        outputText: "BOM 目前还没有确认，成本需要等最终规格确定后再重新核算。",
        applicationRole: .messaging,
        rewriteMode: .expand,
        lengthBudget: .expansion
    ).accepted,
    "扩写质量门接受长度适中且忠实的成稿"
)
check(
    !RewriteQualityGuard.audit(
        sourceText: "这个指标还不能确认，需要验证后才能给结论。",
        outputText: String(repeating: "这个指标仍需验证后再确认。", count: 8),
        applicationRole: .messaging,
        rewriteMode: .expand,
        lengthBudget: .expansion
    ).accepted,
    "扩写质量门拒绝通过重复内容突破长度预算"
)
check(
    !RewriteQualityGuard.audit(
        sourceText: "这次需要确认四项：规格、数量、交期、局部镀范围。",
        outputText: "这次需要确认规格、数量、交期和局部镀范围。",
        applicationRole: .messaging,
        rewriteMode: .expand,
        lengthBudget: .expansion
    ).accepted,
    "明显并列层级未编号换行时会触发重试"
)
check(
    RewriteQualityGuard.audit(
        sourceText: "这次需要确认四项：规格、数量、交期、局部镀范围。",
        outputText: "这次需要确认以下四项：\n1、规格\n2、数量\n3、交期\n4、局部镀范围",
        applicationRole: .messaging,
        rewriteMode: .expand,
        lengthBudget: .expansion
    ).accepted,
    "明显并列层级允许使用编号和适当换行"
)
check(
    !FactGuard.audit(
        sourceText: "这个指标还不能确认，需要验证后才能给结论。",
        result: StructuredRewriteResult(
            rewrittenText: String(repeating: "这个指标仍需验证后再确认。", count: 8)
        ),
        applicationRole: .messaging,
        expansionRatio: 1.35,
        lengthBudget: .expansion
    ).accepted,
    "事实守卫执行扩写模式的独立最大长度预算"
)
check(
    !FactGuard.audit(
        sourceText: "先把报价发给客户，再确认合同，确认后回复我。",
        result: StructuredRewriteResult(
            rewrittenText: "先把报价发给客户，等合同确认好之后，再回复我。"
        ),
        applicationRole: .messaging,
        expansionRatio: 1.35,
        lengthBudget: .expansion
    ).accepted,
    "事实守卫拒绝把主动确认步骤改成被动等待"
)
check(
    FactGuard.audit(
        sourceText: "先把报价发给客户，再确认合同，确认后回复我。",
        result: StructuredRewriteResult(
            rewrittenText: "先把报价发给客户，然后再确认合同。合同确认好以后，记得回复我一声。"
        ),
        applicationRole: .messaging,
        expansionRatio: 1.35,
        lengthBudget: .expansion
    ).accepted,
    "事实守卫接受保留主动步骤的适当扩写"
)
check(
    FactGuard.audit(
        sourceText: "先把报价发给客户，再确认合同，确认后回复我。",
        result: StructuredRewriteResult(
            rewrittenText: "先把报价发给客户，接着去确认合同。等合同确认好后，再回复我。"
        ),
        applicationRole: .messaging,
        expansionRatio: 1.35,
        lengthBudget: .expansion
    ).accepted,
    "事实守卫识别接着确认仍是主动步骤"
)
check(
    FactGuard.audit(
        sourceText: "这个指标原理上做不到：聚焦前后不能同时保持方形光斑。",
        result: StructuredRewriteResult(
            rewrittenText: "这个指标在原理上无法实现，因为聚焦前后无法同时保持方形光斑。"
        ),
        applicationRole: .messaging,
        expansionRatio: 1.35,
        lengthBudget: .expansion
    ).accepted,
    "事实守卫允许展开原文冒号已经明确支持的原理关系"
)
check(
    !FactGuard.audit(
        sourceText: "光斑还是偏大，具体原因还需要分析。",
        result: StructuredRewriteResult(
            rewrittenText: "光斑还是偏大，因为准直镜参数不合适，具体还需要分析。"
        ),
        applicationRole: .messaging,
        expansionRatio: 1.35,
        lengthBudget: .expansion
    ).accepted,
    "原文仅说原因待分析时仍拒绝编造具体原因"
)
check(RewriteQualityCorpus.core.count == 40, "润色质量基线包含 40 条脱敏样例")
check(ExpansionQualityCorpus.core.count == 22, "适当扩写质量基线包含 22 条脱敏样例")
check(
    ContextualExpansionCorpus.core.count == 5
        && ContextualExpansionCorpus.core.allSatisfy { !$0.forbiddenPhrases.isEmpty },
    "上下文扩写质量基线覆盖问题类型、关系与禁止新增内容"
)
check(
    ContextualExpansionCorpus.core.allSatisfy { sample in
        let policy = CommunicationPolicy(
            intent: .inform,
            relationshipRole: sample.relationshipRole,
            relationshipConfidence: sample.relationshipRole == nil ? 0 : 0.9,
            dimensions: sample.relationshipRole.map(RelationshipDimensions.defaults),
            voice: VoiceMetrics(),
            voiceSampleCount: 0,
            customInstruction: nil,
            messageExpansionRatio: 1.35
        )
        let communicationContext = CommunicationContext(
            applicationContext: ApplicationContext(
                bundleIdentifier: "com.tencent.xinwechat",
                displayName: "微信",
                role: .messaging
            ),
            conversationSnapshot: nil,
            relationship: nil,
            intent: .inform,
            voice: VoiceProfile(),
            policy: policy,
            dataConfidence: 0.9
        )
        return ContextualExpansionPlanner.plan(
            sourceText: sample.sourceText,
            communicationContext: communicationContext,
            recentContext: RecentConversationContext(
                questionType: sample.questionType,
                confidence: 0.9
            )
        ).requiresVisibleExpansion == sample.requiresVisibleExpansion
    },
    "上下文扩写语料与本地计划的可感知扩写判定一致"
)
let adaptivePolishMisses = RewriteQualityCorpus.core.filter {
    $0.requiresImprovement
        && AdaptivePolishPolicy.plan(
            for: $0.sourceText,
            applicationRole: $0.category == .development ? .development : .messaging
        ).intensity == .none
}
check(
    adaptivePolishMisses.isEmpty,
    "自适应预检不会跳过质量基线中明确需要改善的文本"
)
check(
    RewriteQualityCorpus.core
        .filter { !$0.requiresImprovement }
        .allSatisfy {
            AdaptivePolishPolicy.plan(
                for: $0.sourceText,
                applicationRole: .messaging
            ).intensity == .none
        },
    "自适应预检会跳过质量基线中无需修改的短消息"
)
let qualityCasesRequiringImprovement = RewriteQualityCorpus.core.filter(\.requiresImprovement)
let retryCoveredQualityCases = qualityCasesRequiringImprovement.filter {
    MessagingRewriteRetryPolicy.shouldRetryUnchanged(
        sourceText: $0.sourceText,
        candidate: $0.sourceText
    )
}
check(
    retryCoveredQualityCases.count >= 28,
    "原样返回重试策略覆盖大部分明确可优化样例"
)
check(
    RewriteQualityCorpus.core
        .filter { !$0.requiresImprovement }
        .allSatisfy {
            !MessagingRewriteRetryPolicy.shouldRetryUnchanged(
                sourceText: $0.sourceText,
                candidate: $0.sourceText
            )
        },
    "质量基线中的自然短消息不会被强制改写"
)
check(
    RewriteAlignmentGuard.audit(
        sourceText: "周总，和俞博讨论了一下，上述指标做不到，原理上好像不对。",
        outputText: "周总，我和俞博讨论了下，这个指标从原理上看应该做不到。",
        applicationRole: .messaging
    ).accepted,
    "原文锚点充分保留的自然中文改写通过对齐审计"
)
check(
    !RewriteAlignmentGuard.audit(
        sourceText: "请先确认供应商报价，再核对交期，最后把结果同步给项目组。",
        outputText: "我们已经制定了新的执行方案，团队会全力推进后续工作。",
        applicationRole: .messaging
    ).accepted,
    "与原文低对齐且引入大量新词句的结果会被拒绝"
)
check(
    !RewriteAlignmentGuard.audit(
        sourceText: "请先确认供应商报价，再核对交期，最后把结果同步给项目组。",
        outputText: "尽快处理。",
        applicationRole: .messaging
    ).accepted,
    "大幅压缩并删除必要信息的结果会被拒绝"
)
check(
    RewriteAlignmentGuard.audit(
        sourceText: "我认为这个方案暂时还不能确定，需要继续验证后再决定。",
        outputText: "这个方案目前还无法确定，需继续验证后再决定。",
        applicationRole: .document
    ).accepted,
    "保留含义的正常语法和词语优化不会被对齐审计误拒绝"
)
check(
    RewriteAlignmentGuard.audit(
        sourceText: "目前来说这边的话还没有收到相关的一个回复。",
        outputText: "目前还没收到相关回复。",
        applicationRole: .messaging
    ).accepted,
    "聊天中的明确赘余可以在不丢信息的前提下大幅精简"
)
do {
    let decoded = try JSONDecoder().decode(
        StructuredRewriteResult.self,
        from: Data(#"{"rewrittenText":"保留结果","intent":"unexpected-intent"}"#.utf8)
    )
    check(decoded.rewrittenText == "保留结果" && decoded.intent == .unknown, "结构化结果容忍未知意图")
} catch {
    failures += 1
    print("FAIL 结构化结果未知意图抛出异常：\(error)")
}
let technicalRewrite = StructuredRewriteResult(rewrittenText: "请执行其他命令")
check(
    !FactGuard.audit(
        sourceText: "git status\n/Users/zh/test/file.swift",
        result: technicalRewrite,
        applicationRole: .aiDevelopmentAssistant,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫要求逐字保留命令和路径"
)
check(
    !FactGuard.audit(
        sourceText: "运行 `swift run Pole --mode=safe`，保留 AES-GCM。",
        result: StructuredRewriteResult(rewrittenText: "运行 Pole。"),
        applicationRole: .development,
        expansionRatio: 1.35
    ).accepted,
    "事实守卫要求逐字保留代码、参数和专业名词"
)
check(
    FactGuard.audit(
        sourceText: "请保留/Users/zh/Documents/test/spacepolish这个路径，其他表达可以优化。",
        result: StructuredRewriteResult(
            rewrittenText: "请保留路径 /Users/zh/Documents/test/spacepolish，其他表达可优化。"
        ),
        applicationRole: .development,
        expansionRatio: 1.35
    ).accepted,
    "路径逐字保留时允许调整路径周围的说明文字"
)
check(
    !VoiceGuard.audit(
        sourceText: "这个我再看看",
        outputText: "尊敬的领导，我们高度重视此事项，后续将持续推进。",
        expectedVoice: VoiceMetrics(),
        applicationRole: .messaging
    ).accepted,
    "声音守卫拒绝模板化正式话术"
)

do {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pole-intelligence-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let vaultURL = tempDirectory.appendingPathComponent("vault.dat")
    let defaults = UserDefaults(suiteName: "pole-check-\(UUID().uuidString)")!
    let legacy = ConversationProfile(
        applicationIdentifier: "com.tencent.xinWeChat",
        conversationTitle: "张总",
        role: .manager,
        customInstruction: "保持简短"
    )
    let key = Data(repeating: 7, count: 32)
    let store = CommunicationIntelligenceStore(
        defaults: defaults,
        legacyProfiles: [legacy],
        fileURL: vaultURL,
        encryptionKey: key
    )
    check(store.relationships.count == 1, "旧聊天对象画像迁移到智能画像库")
    let encrypted = try Data(contentsOf: vaultURL)
    check(!String(decoding: encrypted, as: UTF8.self).contains("张总"), "智能画像文件不会明文保存会话名称")
    let reloaded = CommunicationIntelligenceStore(
        defaults: defaults,
        fileURL: vaultURL,
        encryptionKey: key
    )
    check(reloaded.relationships.first?.role == .manager, "AES-GCM 画像库可以重新加载")

    let historyVaultURL = tempDirectory.appendingPathComponent("history-vault.dat")
    let historyStore = CommunicationIntelligenceStore(
        defaults: defaults,
        fileURL: historyVaultURL,
        encryptionKey: key
    )
    let historyID = historyStore.recordRewrite(
        sourceText: "哈哈，这个我再看看",
        rewrittenText: "哈哈，这个我再看一下",
        applicationRole: .messaging,
        relationshipID: nil,
        conversationID: nil
    )
    check(historyStore.rewriteHistory.count == 1, "成功润色写入本地优化历史")
    check(historyStore.voice.sampleCount == 1, "优化历史立即形成声音画像样本")
    _ = historyStore.recordRewrite(
        sourceText: "运行 swift build 看一下",
        rewrittenText: "运行 swift build 检查构建结果",
        applicationRole: .development,
        relationshipID: nil,
        conversationID: nil
    )
    check(
        historyStore.rewriteHistory.count == 2 && historyStore.voice.sampleCount == 1,
        "开发和文档历史不会污染聊天声音画像"
    )
    let encryptedHistory = try Data(contentsOf: historyVaultURL)
    let encryptedHistoryText = String(decoding: encryptedHistory, as: UTF8.self)
    check(
        !encryptedHistoryText.contains("这个我再看看") && !encryptedHistoryText.contains("这个我再看一下"),
        "优化历史原文和结果不会明文落盘"
    )
    let reloadedHistoryStore = CommunicationIntelligenceStore(
        defaults: defaults,
        fileURL: historyVaultURL,
        encryptionKey: key
    )
    check(
        reloadedHistoryStore.rewriteHistory.contains { $0.sourceText == "哈哈，这个我再看看" },
        "加密优化历史可以重新加载"
    )
    reloadedHistoryStore.applyFeedback(.good, relationshipID: nil, historyEntryID: historyID)
    check(
        reloadedHistoryStore.rewriteHistory.first(where: { $0.id == historyID })?.feedback == .good,
        "最近一次反馈会写回对应历史"
    )
    reloadedHistoryStore.clearRewriteHistory()
    check(reloadedHistoryStore.rewriteHistory.isEmpty, "优化历史可以单独清空")
    var changedProbabilities = RoleProbabilities()
    changedProbabilities.customer = 0.86
    changedProbabilities.manager = 0.18
    let changedAnalysis = RelationshipAnalysis(
        role: .customer,
        probabilities: changedProbabilities,
        confidence: 0.86,
        evidence: ["对话转为合同与交付语境"],
        dimensions: .defaults(for: .customer)
    )
    let migrationSnapshot = ConversationSnapshot(
        applicationIdentifier: "com.tencent.xinWeChat",
        processIdentifier: 42,
        windowIdentifier: 12,
        candidate: ConversationTitleCandidate(title: "张总", source: .windowTitle, confidence: 0.96)
    )
    let firstObservation = Date()
    _ = reloaded.applyAnalysis(
        changedAnalysis,
        snapshot: migrationSnapshot,
        conversationID: "c",
        messages: [],
        analyzedAt: firstObservation
    )
    _ = reloaded.applyAnalysis(
        changedAnalysis,
        snapshot: migrationSnapshot,
        conversationID: "c",
        messages: [],
        analyzedAt: firstObservation.addingTimeInterval(86_401)
    )
    check(reloaded.relationships.first?.pendingChange?.observationCount == 2, "关系变化需要连续两次观察")
    if let id = reloaded.relationships.first?.id { reloaded.confirmPendingChange(id: id) }
    check(reloaded.relationships.first?.role == .customer, "关系变化只有确认后才生效")
    let voiceMessages = [
        ConversationMessage(id: "s1", conversationID: "c", timestamp: Date(), direction: .sent, senderID: nil, kind: .text, text: "哈哈，可以"),
        ConversationMessage(id: "s2", conversationID: "c", timestamp: Date(), direction: .sent, senderID: nil, kind: .text, text: "行，我再看一下"),
        ConversationMessage(id: "s3", conversationID: "c", timestamp: Date(), direction: .sent, senderID: nil, kind: .text, text: "好的，晚点同步"),
        ConversationMessage(id: "r1", conversationID: "c", timestamp: Date(), direction: .received, senderID: nil, kind: .text, text: "您好，感谢您的理解与支持，敬请知悉")
    ]
    let stableAnalysis = RelationshipAnalysis(
        role: .customer,
        probabilities: changedProbabilities,
        confidence: 0.86,
        evidence: ["保持当前关系"],
        dimensions: .defaults(for: .customer)
    )
    _ = reloaded.applyAnalysis(
        stableAnalysis,
        snapshot: migrationSnapshot,
        conversationID: "c",
        messages: voiceMessages,
        analyzedAt: firstObservation.addingTimeInterval(172_802)
    )
    check(reloaded.voice.sampleCount == 3, "声音学习只统计本人已发送文本")
    check(reloaded.voice.metrics.formality < 0.5, "收到的正式话术不会污染用户声音")
    reloaded.resetVoice()
    reloaded.clearAll()
    check(reloaded.relationships.isEmpty, "全部智能数据可以清除")
    check(!FileManager.default.fileExists(atPath: vaultURL.path), "清除智能数据会删除加密画像文件")
    try? FileManager.default.removeItem(at: tempDirectory)
} catch {
    failures += 1
    print("FAIL  加密画像检查抛出异常：\(error)")
}

do {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pole-helper-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let helperURL = tempDirectory.appendingPathComponent("fake-helper")
    let script = """
    #!/bin/sh
    case "$1" in
      capabilities)
        printf '%s' '{"protocolVersion":1,"provider":"fixture","supportsSessions":true,"supportsHistory":true,"readOnly":true}'
        ;;
      sessions)
        printf '%s' '{"protocolVersion":1,"status":"ok","sessions":[{"id":"one","title":"张总","type":"private","lastActivity":null},{"id":"two","title":"张总","type":"private","lastActivity":null}]}'
        ;;
      history)
        printf '%s' '{"protocolVersion":1,"status":"ok","messages":[]}'
        ;;
    esac
    """
    try Data(script.utf8).write(to: helperURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    let provider = ExternalHelperProvider(executableURL: helperURL)
    switch waitForAsync({ try await provider.capabilities() }) {
    case .success(let capabilities):
        check(capabilities.readOnly && capabilities.protocolVersion == 1, "helper 能力协商接受只读协议 v1")
    case .failure(let error):
        failures += 1
        print("FAIL  helper 能力协商：\(error)")
    }

    let approvedIdentity: HelperIdentity
    switch waitForAsync({ try await HelperIdentityService().inspect(helperURL) }) {
    case .success(let identity):
        approvedIdentity = identity
        check(identity.sha256.count == 64, "helper 身份包含 SHA-256")
        check(
            identity.signature == .unsigned
                && identity.signature.displayText == "未签名",
            "未签名 helper 会明确展示签名状态"
        )
    case .failure(let error):
        throw error
    }
    let trustSuiteName = "PoleHelperTrustChecks-\(UUID().uuidString)"
    let trustDefaults = UserDefaults(suiteName: trustSuiteName)!
    defer { trustDefaults.removePersistentDomain(forName: trustSuiteName) }
    let trustStore = HelperTrustStore(defaults: trustDefaults)
    trustStore.approve(approvedIdentity)
    check(trustStore.approvedIdentity == approvedIdentity, "helper 信任身份可以持久化")

    let changedHelperURL = tempDirectory.appendingPathComponent("changed-helper")
    try Data(script.utf8).write(to: changedHelperURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: changedHelperURL.path
    )
    let changedApprovedIdentity: HelperIdentity
    switch waitForAsync({ try await HelperIdentityService().inspect(changedHelperURL) }) {
    case .success(let identity): changedApprovedIdentity = identity
    case .failure(let error): throw error
    }
    try Data("#!/bin/sh\nprintf '{}'".utf8).write(to: changedHelperURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: changedHelperURL.path
    )
    switch waitForAsync({
        try await ExternalHelperProvider(
            executableURL: changedHelperURL,
            approvedIdentity: changedApprovedIdentity
        ).capabilities()
    }) {
    case .success:
        check(false, "helper 文件变化后必须重新确认")
    case .failure(let error):
        check(
            (error as? ConversationHelperError) == .helperIdentity(.changed),
            "helper 文件变化后必须重新确认"
        )
    }
    let helperSnapshot = ConversationSnapshot(
        applicationIdentifier: "com.tencent.xinWeChat",
        processIdentifier: 42,
        windowIdentifier: 12,
        candidate: ConversationTitleCandidate(title: "张总", source: .windowTitle, confidence: 0.96)
    )
    switch waitForAsync({ try await provider.resolveSession(for: helperSnapshot) }) {
    case .success:
        failures += 1
        print("FAIL  helper 重名会话必须拒绝自动匹配")
    case .failure(let error):
        check((error as? ConversationHelperError) == .ambiguousSession, "helper 重名会话必须拒绝自动匹配")
    }

    let isoFormatter = ISO8601DateFormatter()
    let recentTimestamp = isoFormatter.string(from: Date().addingTimeInterval(-60))
    let staleTimestamp = isoFormatter.string(from: Date().addingTimeInterval(-40 * 86_400))
    let historyURL = tempDirectory.appendingPathComponent("history-helper")
    let historyJSON = """
    {"protocolVersion":1,"status":"ok","messages":[
      {"id":"old","conversationID":"c","timestamp":"\(staleTimestamp)","direction":"sent","senderID":null,"kind":"text","text":"陈旧分片"},
      {"id":"image","conversationID":"c","timestamp":"\(recentTimestamp)","direction":"received","senderID":null,"kind":"image","text":"图片描述"},
      {"id":"recent","conversationID":"c","timestamp":"\(recentTimestamp)","direction":"sent","senderID":null,"kind":"text","text":"最近文本"}
    ]}
    """
    try Data("#!/bin/sh\nprintf '%s' '\(historyJSON)'".utf8).write(to: historyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: historyURL.path)
    switch waitForAsync({
        try await ExternalHelperProvider(executableURL: historyURL).history(
            conversationID: "c",
            limit: 200,
            days: 30
        )
    }) {
    case .success(let messages):
        check(messages.map(\.id) == ["recent"], "helper 历史会过滤陈旧分片和非文本消息")
    case .failure(let error):
        failures += 1
        print("FAIL  helper 历史过滤：\(error)")
    }

    let malformedURL = tempDirectory.appendingPathComponent("malformed-helper")
    try Data("#!/bin/sh\nprintf 'not-json'".utf8).write(to: malformedURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: malformedURL.path)
    switch waitForAsync({ try await ExternalHelperProvider(executableURL: malformedURL).capabilities() }) {
    case .success:
        failures += 1
        print("FAIL  helper 损坏 JSON 必须拒绝")
    case .failure(let error):
        check((error as? ConversationHelperError) == .invalidJSON, "helper 损坏 JSON 必须拒绝")
    }

    let incompatibleURL = tempDirectory.appendingPathComponent("incompatible-helper")
    try Data("#!/bin/sh\nprintf '%s' '{\"protocolVersion\":2,\"provider\":\"fixture\",\"supportsSessions\":true,\"supportsHistory\":true,\"readOnly\":true}'".utf8).write(to: incompatibleURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: incompatibleURL.path)
    switch waitForAsync({ try await ExternalHelperProvider(executableURL: incompatibleURL).capabilities() }) {
    case .success:
        failures += 1
        print("FAIL  helper 未知协议版本必须拒绝")
    case .failure(let error):
        check((error as? ConversationHelperError) == .incompatibleProtocol(2), "helper 未知协议版本必须拒绝")
    }

    let writableURL = tempDirectory.appendingPathComponent("writable-helper")
    try Data("#!/bin/sh\nprintf '%s' '{\"protocolVersion\":1,\"provider\":\"fixture\",\"supportsSessions\":true,\"supportsHistory\":true,\"readOnly\":false}'".utf8).write(to: writableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: writableURL.path)
    switch waitForAsync({ try await ExternalHelperProvider(executableURL: writableURL).capabilities() }) {
    case .success:
        failures += 1
        print("FAIL  非只读 helper 必须拒绝")
    case .failure(let error):
        check((error as? ConversationHelperError) == .notReadOnly, "非只读 helper 必须拒绝")
    }

    let oversizedURL = tempDirectory.appendingPathComponent("oversized-helper")
    try Data("#!/bin/sh\nprintf 'abcdefghijklmnopqrstuvwxyz'".utf8).write(to: oversizedURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oversizedURL.path)
    switch waitForAsync({
        try await HelperProcessRunner().run(
            executableURL: oversizedURL,
            arguments: [],
            timeout: 1,
            maximumOutputBytes: 10
        )
    }) {
    case .success:
        failures += 1
        print("FAIL  helper 超大输出必须拒绝")
    case .failure(let error):
        check((error as? ConversationHelperError) == .outputTooLarge, "helper 超大输出必须拒绝")
    }

    let failedURL = tempDirectory.appendingPathComponent("failed-helper")
    try Data("#!/bin/sh\nprintf 'fixture error' >&2\nexit 3".utf8).write(to: failedURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failedURL.path)
    switch waitForAsync({
        try await HelperProcessRunner().run(
            executableURL: failedURL,
            arguments: [],
            timeout: 1,
            maximumOutputBytes: 1_024
        )
    }) {
    case .success:
        failures += 1
        print("FAIL  helper 异常退出必须拒绝")
    case .failure(let error):
        if let helperError = error as? ConversationHelperError,
           case .nonzeroExit(let code, _) = helperError,
           code == 3 {
            check(true, "helper 异常退出必须拒绝")
        } else {
            check(false, "helper 异常退出必须拒绝")
        }
    }

    let missingURL = tempDirectory.appendingPathComponent("missing-helper")
    switch waitForAsync({
        try await HelperProcessRunner().run(
            executableURL: missingURL,
            arguments: [],
            timeout: 1,
            maximumOutputBytes: 1_024
        )
    }) {
    case .success:
        failures += 1
        print("FAIL  helper 缺失必须安全失败")
    case .failure(let error):
        check((error as? ConversationHelperError) == .missingExecutable, "helper 缺失必须安全失败")
    }

    let slowURL = tempDirectory.appendingPathComponent("slow-helper")
    try Data("#!/bin/sh\nsleep 2\nprintf '{}'".utf8).write(to: slowURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowURL.path)
    switch waitForAsync({
        try await HelperProcessRunner().run(
            executableURL: slowURL,
            arguments: [],
            timeout: 0.1,
            maximumOutputBytes: 1_024
        )
    }) {
    case .success:
        failures += 1
        print("FAIL  helper 超时必须终止")
    case .failure(let error):
        check((error as? ConversationHelperError) == .timedOut, "helper 超时必须终止")
    }

    let cancellableURL = tempDirectory.appendingPathComponent("cancellable-helper")
    try Data("#!/bin/sh\nsleep 5\nprintf '{}'".utf8).write(to: cancellableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cancellableURL.path)
    let cancellationStarted = Date()
    switch waitForAsync({
        let task = Task {
            try await HelperProcessRunner().run(
                executableURL: cancellableURL,
                arguments: [],
                timeout: 10,
                maximumOutputBytes: 1_024
            )
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        return try await task.value
    }) {
    case .success:
        check(false, "取消任务会终止 helper 子进程")
    case .failure(let error):
        check(
            error is CancellationError && Date().timeIntervalSince(cancellationStarted) < 2,
            "取消任务会终止 helper 子进程"
        )
    }
    try? FileManager.default.removeItem(at: tempDirectory)
} catch {
    failures += 1
    print("FAIL  helper fixture 检查抛出异常：\(error)")
}

if failures > 0 {
    print("\n\(failures) 项检查失败")
} else {
    print("\n全部检查通过")
}
return failures
}

#if POLE_STANDALONE_CHECKS
let result = runPoleRegressionChecks()
if result > 0 {
    exit(1)
}
#endif

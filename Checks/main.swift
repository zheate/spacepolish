import Foundation

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
    "通用回退排除终端"
)
check(
    !KeyboardFallbackPolicy.allows(bundleIdentifier: "com.spacepolish.mac"),
    "通用回退排除自身"
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
    PromptPolicy.polishPrompt(basePrompt: "基础规则", contextInstruction: nil) == "基础规则",
    "没有场景规则时保持原提示词"
)
check(
    PromptPolicy.polishPrompt(basePrompt: " \n", contextInstruction: nil)
        == PromptPolicy.currentDefault,
    "请求阶段不会发送空白系统提示词"
)
check(
    PromptPolicy.currentDefault.contains("保持原文的确定程度")
        && PromptPolicy.currentDefault.contains("避免公文腔、模板腔")
        && PromptPolicy.currentDefault.contains("保留口语中自然省略的成分")
        && PromptPolicy.currentDefault.contains("讨论了下")
        && PromptPolicy.currentDefault.contains("动作及其对象、受益人、目的和先后关系")
        && PromptPolicy.currentDefault.contains("简洁不是越短越好")
        && PromptPolicy.currentDefault.contains("不要为了显得精炼而删减信息")
        && PromptPolicy.currentDefault.contains("默认应给出经过优化的版本")
        && PromptPolicy.currentDefault.contains("必须至少完成一处")
        && PromptPolicy.currentDefault.contains("才原样返回")
        && !PromptPolicy.currentDefault.contains("优先原样输出"),
    "新版提示词兼顾信息保留和主动有效修改"
)
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
check(!QwenClient.enableThinking, "Qwen 3.7 Plus 关闭思考模式")

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
    )?.contains("礼貌不等于正式") == true,
    "聊天客户端始终使用自然即时消息规则"
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
    try? FileManager.default.removeItem(at: tempDirectory)
} catch {
    failures += 1
    print("FAIL  helper fixture 检查抛出异常：\(error)")
}

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}

print("\n全部检查通过")

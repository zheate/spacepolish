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

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}

print("\n全部检查通过")

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
    KeyboardFallbackPolicy.allows(bundleIdentifier: "com.apple.Terminal"),
    "通用回退允许终端"
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
    chineseEditingPrompt.contains("成分残缺或赘余")
        && chineseEditingPrompt.contains("词义、词性、固定搭配、语域、领域常用表达")
        && chineseEditingPrompt.contains("发现多处问题时逐一修正")
        && chineseEditingPrompt.contains("禁止附加“优化说明”")
        && chineseEditingPrompt.contains("聊天规则"),
    "润色请求包含中文语法、词语搭配和原文对齐规则"
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
    ) == .completion,
    "翻译完成始终使用确认音"
)
check(
    InputProgressSoundCue.completion.soundName == "Glass",
    "完成态使用灯泡点亮感的清亮音效"
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
    neutralCommunicationPolicy.modelInstruction.contains("至少完成一处具体改进")
        && neutralCommunicationPolicy.modelInstruction.contains("只有原文已经自然准确时才保持不变")
        && !neutralCommunicationPolicy.modelInstruction.contains("只做最小必要修改"),
    "沟通策略不会抵消主动优化规则"
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
    MessagingRewriteRetryPolicy.shouldRetryUnchanged(
        sourceText: "这个方案我再看看",
        candidate: "这个方案我再看看"
    ),
    "较完整聊天原样返回时再尝试一次有效改写"
)
check(
    !MessagingRewriteRetryPolicy.shouldRetryUnchanged(
        sourceText: "好的",
        candidate: "好的"
    ),
    "自然短回复不为制造变化而重复请求"
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
    !RewriteHighlightPlanner.plan(
        sourceText: "无需修改",
        outputText: "无需修改"
    ).hasChanges,
    "相同文本不显示优化高亮"
)
let embeddedHighlightPlan = RewriteHighlightPlanner.plan(
    sourceText: "加电过程中会突然通讯中断，随后一直报错。",
    outputText: "上电过程中通信会突然中断，随后持续报错。"
)
check(
    embeddedHighlightPlan.hasChanges && embeddedHighlightPlan.changeCount >= 3,
    "嵌入式术语、语序和搭配修改会形成多处高亮"
)
let embeddedHighlightText = "上电过程中通信会突然中断，随后持续报错。" as NSString
check(
    embeddedHighlightPlan.ranges.allSatisfy {
        UTF16TextRangeValidator.isValid($0, forLength: embeddedHighlightText.length)
    },
    "所有优化高亮范围都使用有效的结果文本 UTF-16 坐标"
)
check(
    RewriteHighlightPlanner.plan(
        sourceText: "正文。怎么优化？",
        outputText: "正文。"
    ).ranges == [NSRange(location: 3, length: 0)],
    "纯删除会在结果中的删除位置生成零宽高亮"
)
check(
    RewriteHighlightPlanner.plan(
        sourceText: "A🙂B",
        outputText: "A😀B"
    ).ranges == [NSRange(location: 1, length: 2)],
    "优化高亮范围正确处理 emoji 的 UTF-16 长度"
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

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
        cursorUTF16: (input as NSString).length
    )
    check(plan.capturedText == input, "Option 触发不修改原文")
    check(plan.sourceText == "这个表达有一点不太好", "选择单行正文")
    check(plan.replacementRange == NSRange(location: 0, length: 10), "计算 UTF-16 范围")
} catch {
    failures += 1
    print("FAIL  单行规划抛出异常：\(error)")
}

do {
    let input = "第一段保持不变\n第二段需要润色"
    let plan = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    check(plan.sourceText == "第二段需要润色", "只选择当前段落")
    check(
        (input as NSString).substring(with: plan.replacementRange) == "第二段需要润色",
        "当前段落替换范围正确"
    )
} catch {
    failures += 1
    print("FAIL  多段规划抛出异常：\(error)")
}

do {
    let input = "    缩进内容"
    let plan = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    check(plan.sourceText == "缩进内容", "不把缩进发送给 AI")
    check(plan.replacementRange.location == 4, "保留段落缩进")
} catch {
    failures += 1
    print("FAIL  缩进规划抛出异常：\(error)")
}

do {
    let input = "保留正文后的空格  "
    let plan = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    check(plan.sourceText == "保留正文后的空格", "发送正文时排除尾部空格")
    let commit = try TextCommitPlanner.plan(
        currentText: input,
        capturedText: plan.capturedText,
        sourceRange: plan.replacementRange,
        replacement: "正文已优化"
    )
    check(commit.updatedText == "正文已优化  ", "Option 触发保留原有尾部空格")
} catch {
    failures += 1
    print("FAIL  尾部空格规划抛出异常：\(error)")
}

do {
    let input = "光标前文字光标后文字"
    let cursor = ("光标前文字" as NSString).length
    let plan = try TextRangePlanner.plan(text: input, cursorUTF16: cursor)
    check(plan.sourceText == "光标前文字", "只优化光标前的当前段落内容")
} catch {
    failures += 1
    print("FAIL  段落中间光标规划抛出异常：\(error)")
}

expectThrow("拒绝超出文本范围的光标") {
    let input = "光标位置异常"
    _ = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length + 1
    )
}

do {
    let input = "原文需要优化"
    let rewrite = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
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
        cursorUTF16: (input as NSString).length
    )
    _ = try TextCommitPlanner.plan(
        currentText: "用户已经修改",
        capturedText: rewrite.capturedText,
        sourceRange: rewrite.replacementRange,
        replacement: "优化后的文字"
    )
}

do {
    let input = "需要优化\n后续内容"
    let triggerCursor = ("需要优化" as NSString).length
    let rewrite = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: triggerCursor
    )
    let commit = try TextCommitPlanner.plan(
        currentText: input,
        capturedText: rewrite.capturedText,
        sourceRange: rewrite.replacementRange,
        replacement: "已经优化"
    )
    check(commit.updatedText == "已经优化\n后续内容", "保留触发位置之后的文本")
    check(
        commit.cursorUTF16 == ("已经优化" as NSString).length,
        "写回后光标位于优化结果末尾"
    )
} catch {
    failures += 1
    print("FAIL  中间段落光标规划抛出异常：\(error)")
}

expectThrow("拒绝空段落") {
    let input = "上一段\n"
    _ = try TextRangePlanner.plan(text: input, cursorUTF16: (input as NSString).length)
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
    PromptPolicy.resolvedPrompt(from: "请保持简洁") == "请保持简洁",
    "保留用户自定义提示词"
)
check(
    PromptPolicy.currentDefault.contains("保持原文的确定程度")
        && PromptPolicy.currentDefault.contains("避免公文腔、模板腔")
        && PromptPolicy.currentDefault.contains("必须至少完成一处"),
    "新版提示词约束语义强度和表达风格"
)
check(
    TranslationPolicy.prompt.contains("主要是中文")
        && TranslationPolicy.prompt.contains("简体中文")
        && TranslationPolicy.prompt.contains("只输出翻译结果"),
    "翻译规则支持中译英和外语译中"
)
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
check(QwenClient.temperature == 0.5, "模型温度保持为 0.5")
check(!QwenClient.enableThinking, "Qwen 3.7 Plus 关闭思考模式")

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}

print("\n全部检查通过")

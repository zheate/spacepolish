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

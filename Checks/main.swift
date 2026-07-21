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
    let input = "这个表达有一点不太好  "
    let plan = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    check(plan.cleanedText == "这个表达有一点不太好", "移除触发空格")
    check(plan.sourceText == "这个表达有一点不太好", "选择单行正文")
    check(plan.triggerRange == NSRange(location: 10, length: 2), "记录触发空格范围")
    check(plan.replacementRange == NSRange(location: 0, length: 10), "计算 UTF-16 范围")
} catch {
    failures += 1
    print("FAIL  单行规划抛出异常：\(error)")
}

do {
    let input = "第一段保持不变\n第二段需要润色  "
    let plan = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    check(plan.sourceText == "第二段需要润色", "只选择当前段落")
    check(
        (plan.cleanedText as NSString).substring(with: plan.replacementRange) == "第二段需要润色",
        "当前段落替换范围正确"
    )
} catch {
    failures += 1
    print("FAIL  多段规划抛出异常：\(error)")
}

do {
    let input = "    缩进内容  "
    let plan = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    check(plan.sourceText == "缩进内容", "不把缩进发送给 AI")
    check(plan.replacementRange.location == 4, "保留段落缩进")
    check(plan.cleanedText == "    缩进内容", "清理后文本保留缩进")
} catch {
    failures += 1
    print("FAIL  缩进规划抛出异常：\(error)")
}

expectThrow("拒绝缺失触发空格的文本") {
    let input = "没有触发空格"
    _ = try TextRangePlanner.plan(text: input, cursorUTF16: (input as NSString).length)
}

do {
    let input = "光标位置稍慢  "
    let plan = try TextRangePlanner.plan(text: input, cursorUTF16: 6)
    check(plan.cleanedText == "光标位置稍慢", "兼容落后于文本的光标位置")
    check(plan.cursorUTF16 == 6, "使用实际触发空格位置恢复光标")
} catch {
    failures += 1
    print("FAIL  滞后光标规划抛出异常：\(error)")
}

do {
    let input = "光标被重置  "
    let plan = try TextRangePlanner.plan(text: input, cursorUTF16: 0)
    check(plan.cleanedText == "光标被重置", "兼容被临时重置到开头的光标")
} catch {
    failures += 1
    print("FAIL  首位光标规划抛出异常：\(error)")
}

do {
    let input = "光标位置超前  "
    let plan = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length + 1
    )
    check(plan.cleanedText == "光标位置超前", "兼容暂时超前于文本的光标位置")
} catch {
    failures += 1
    print("FAIL  超前光标规划抛出异常：\(error)")
}

do {
    let input = "原文需要优化  "
    let rewrite = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    let commit = try TextCommitPlanner.plan(
        currentText: input,
        capturedText: rewrite.capturedText,
        cleanedText: rewrite.cleanedText,
        triggerRange: rewrite.triggerRange,
        sourceRange: rewrite.replacementRange,
        replacement: "优化后的文字"
    )
    check(commit.updatedText == "优化后的文字", "一次性写回正文并移除触发空格")
    check(commit.cursorUTF16 == 6, "写回后光标位于结果末尾")
} catch {
    failures += 1
    print("FAIL  原始触发文本提交抛出异常：\(error)")
}

do {
    let input = "原文需要优化  "
    let rewrite = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    let commit = try TextCommitPlanner.plan(
        currentText: rewrite.cleanedText,
        capturedText: rewrite.capturedText,
        cleanedText: rewrite.cleanedText,
        triggerRange: rewrite.triggerRange,
        sourceRange: rewrite.replacementRange,
        replacement: "优化后的文字"
    )
    check(commit.updatedText == "优化后的文字", "兼容输入框自行清除触发空格")
} catch {
    failures += 1
    print("FAIL  自动清理空格提交抛出异常：\(error)")
}

expectThrow("等待期间真实编辑仍拒绝覆盖") {
    let input = "原文需要优化  "
    let rewrite = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: (input as NSString).length
    )
    _ = try TextCommitPlanner.plan(
        currentText: "用户已经修改",
        capturedText: rewrite.capturedText,
        cleanedText: rewrite.cleanedText,
        triggerRange: rewrite.triggerRange,
        sourceRange: rewrite.replacementRange,
        replacement: "优化后的文字"
    )
}

do {
    let input = "需要优化  \n后续内容"
    let triggerCursor = ("需要优化  " as NSString).length
    let rewrite = try TextRangePlanner.plan(
        text: input,
        cursorUTF16: triggerCursor
    )
    let commit = try TextCommitPlanner.plan(
        currentText: input,
        capturedText: rewrite.capturedText,
        cleanedText: rewrite.cleanedText,
        triggerRange: rewrite.triggerRange,
        sourceRange: rewrite.replacementRange,
        replacement: "已经优化"
    )
    check(commit.updatedText == "已经优化\n后续内容", "保留触发位置之后的文本")
    check(
        commit.cursorUTF16 == (commit.updatedText as NSString).length,
        "写回后光标始终位于全文末尾"
    )
} catch {
    failures += 1
    print("FAIL  全文末尾光标规划抛出异常：\(error)")
}

expectThrow("拒绝空段落") {
    let input = "上一段\n  "
    _ = try TextRangePlanner.plan(text: input, cursorUTF16: (input as NSString).length)
}

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
    OptimizationOutcome.classify(sourceText: "无需改动", result: "无需改动")
        == .unchanged,
    "相同结果归类为红色未改变"
)
check(
    OptimizationOutcome.classify(
        sourceText: "这句话有一点不通顺",
        result: "这句话有一点不够通顺"
    ) == .partial,
    "小范围修改归类为黄色部分优化"
)
check(
    OptimizationOutcome.classify(
        sourceText: "这个写得不好",
        result: "请重新整理这段表达，使其更清晰自然"
    ) == .complete,
    "明显改写归类为绿色完全优化"
)
check(DeepSeekClient.temperature == 0.5, "模型温度提高到 0.5")

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}

print("\n全部检查通过")

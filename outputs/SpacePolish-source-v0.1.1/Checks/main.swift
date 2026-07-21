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

expectThrow("拒绝空段落") {
    let input = "上一段\n  "
    _ = try TextRangePlanner.plan(text: input, cursorUTF16: (input as NSString).length)
}

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}

print("\n全部检查通过")

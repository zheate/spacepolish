import Foundation

struct StructuredRewriteResult: Codable, Equatable {
    let rewrittenText: String
    let intent: CommunicationIntent
    let preservedClaims: [String]
    let addedClaims: [String]
    let certaintyChanges: [String]

    enum CodingKeys: String, CodingKey {
        case rewrittenText
        case intent
        case preservedClaims
        case addedClaims
        case certaintyChanges
    }

    init(
        rewrittenText: String,
        intent: CommunicationIntent = .unknown,
        preservedClaims: [String] = [],
        addedClaims: [String] = [],
        certaintyChanges: [String] = []
    ) {
        self.rewrittenText = rewrittenText
        self.intent = intent
        self.preservedClaims = preservedClaims
        self.addedClaims = addedClaims
        self.certaintyChanges = certaintyChanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rewrittenText = try container.decode(String.self, forKey: .rewrittenText)
        let rawIntent = try container.decodeIfPresent(String.self, forKey: .intent)
        intent = rawIntent.flatMap(CommunicationIntent.init(rawValue:)) ?? .unknown
        preservedClaims = try container.decodeIfPresent([String].self, forKey: .preservedClaims) ?? []
        addedClaims = try container.decodeIfPresent([String].self, forKey: .addedClaims) ?? []
        certaintyChanges = try container.decodeIfPresent([String].self, forKey: .certaintyChanges) ?? []
    }
}

struct FactAuditResult: Equatable {
    let accepted: Bool
    let issues: [String]
    let protectedTokens: [String]
}

struct VoiceAuditResult: Equatable {
    let accepted: Bool
    let issues: [String]
}

struct RewriteAlignmentAuditResult: Equatable {
    let accepted: Bool
    let issues: [String]
    let retainedSourceRatio: Double
    let introducedOutputRatio: Double
}

struct RewriteQualityAuditResult: Equatable {
    let accepted: Bool
    let issues: [String]
    let meaningfullyChanged: Bool
}

enum RewriteSafetyError: LocalizedError {
    case rejected([String])
    case qualityRejected([String])

    var errorDescription: String? {
        switch self {
        case .rejected(let issues):
            let detail = issues.prefix(2).joined(separator: "；")
            return detail.isEmpty
                ? "候选结果未通过本地事实与声音检查"
                : "候选结果未通过安全检查：\(detail)"
        case .qualityRejected(let issues):
            let detail = issues.prefix(2).joined(separator: "；")
            return detail.isEmpty
                ? "候选结果没有达到可直接使用的质量"
                : "候选结果仍不够好：\(detail)"
        }
    }
}

enum FactGuard {
    private static let protectedPatterns = [
        #"(?s)```.*?```"#,
        #"https?://[^\s]+"#,
        #"`[^`]+`"#,
        #"(?:/|~/)[A-Za-z0-9_./\-]+"#,
        #"(?:[A-Za-z]:\\)[^\s]+"#,
        #"--[A-Za-z0-9][A-Za-z0-9_\-]*(?:=[^\s]+)?"#,
        #"\b[A-Za-z_][A-Za-z0-9_]*=[^\s,;]+"#,
        #"\b[A-Z][A-Za-z0-9]*(?:[-_.][A-Za-z0-9]+)+\b"#,
        #"[“「\"]([^”」\"]{1,80})[”」\"]"#,
        #"\b\d+(?:\.\d+)?\s*(?:%|％|ms|s|秒|分钟|小时|天|周|月|年|mm|cm|m|nm|μm|um|W|kW|A|V|Hz|kHz|MHz|GHz|℃|°C)?\b"#,
        #"\d{4}[./-]\d{1,2}[./-]\d{1,2}"#,
        #"[\p{Han}]{1,4}(?:总|老师|经理|主任|博士)"#
    ]
    private static let negativeMarkers = ["不", "没", "未", "不能", "无法", "不要", "并非", "否认"]
    private static let uncertainMarkers = ["可能", "也许", "大概", "预计", "应该", "似乎", "风险", "暂时"]
    private static let certainMarkers = ["已经", "确定", "一定", "必然", "确认", "肯定", "完成了"]
    private static let sequenceMarkers = [
        "先", "首先", "再", "然后", "随后", "接着", "之前", "以前", "之后", "以后",
        "后再", "完再", "完了再"
    ]
    private static let actionMarkerGroups = [
        ["发送", "发给", "转发", "发过去", "发过来", "发一下", "发下"],
        ["确认", "核实", "查一下", "查下"],
        ["通知", "告知", "同步", "告诉", "说一声", "说一下", "说下"],
        ["提交", "交付", "提供", "给到"],
        ["修改", "调整", "更新", "改一下", "改下", "改成", "改掉"],
        ["删除", "移除", "取消", "删掉", "删一下", "删下"],
        ["付款", "支付", "打款", "转账"],
        ["安排", "预约", "排期", "约一下", "约下"],
        ["完成", "做完", "弄完", "搞定"],
        ["拒绝", "不同意", "不接受"],
        ["回复", "答复", "反馈", "回我", "回你", "回他", "回她", "回一下", "回下"],
        ["打开", "开启", "开一下", "开下"],
        ["吃", "喝", "吃掉", "喝掉"]
    ]
    private static let riskyIntroductions: [(label: String, markers: [String])] = [
        ("时间", ["今天", "明天", "后天", "本周", "下周", "周一", "周二", "周三", "周四", "周五", "月底"]),
        ("原因", ["因为", "由于", "原因是", "主要原因", "之所以"]),
        ("承诺", ["我会", "我们会", "将会", "保证", "确保", "一定会", "马上", "及时跟进", "持续推进"])
    ]

    static func audit(
        sourceText: String,
        result: StructuredRewriteResult,
        applicationRole: ApplicationWritingRole,
        expansionRatio: Double,
        semanticLibraries: Set<SemanticLibraryID> = SemanticLibraryID.defaultEnabled,
        lengthBudget: RewriteLengthBudget? = nil
    ) -> FactAuditResult {
        let output = result.rewrittenText
        var issues: [String] = []
        let tokens = protectedTokens(
            in: sourceText,
            semanticLibraries: semanticLibraries
        )
        for token in tokens where !output.localizedCaseInsensitiveContains(token) {
            issues.append("缺少受保护内容：\(token)")
        }

        // The model's claim report is advisory metadata, not evidence. The
        // deterministic checks below must decide whether the rewritten text is
        // safe; otherwise an honest self-report can reject an otherwise valid
        // rewrite, while an incorrect self-report would not improve safety.

        if containsAny(negativeMarkers, in: sourceText), !containsAny(negativeMarkers, in: output) {
            issues.append("否定关系可能被删除")
        }
        if containsAny(uncertainMarkers, in: sourceText),
           !containsAny(uncertainMarkers, in: output),
           containsAny(certainMarkers, in: output) {
            issues.append("不确定表达被改成确定结论")
        }
        if !containsAny(certainMarkers, in: sourceText),
           containsAny(["一定", "必然", "已确认"], in: output) {
            issues.append("输出新增了确定性结论")
        }

        for introduction in riskyIntroductions
            where !containsAny(introduction.markers, in: sourceText)
                && containsAny(introduction.markers, in: output) {
            if introduction.label == "原因",
               containsExplicitExplanatoryRelation(in: sourceText) {
                continue
            }
            issues.append("输出擅自增加\(introduction.label)信息")
        }
        if !containsResponsibilityAssignment(in: sourceText), containsResponsibilityAssignment(in: output) {
            issues.append("输出擅自增加责任人或任务分配")
        }

        if containsAny(sequenceMarkers, in: sourceText),
           !containsAny(sequenceMarkers, in: output),
           isLikelyInformationLoss(sourceText: sourceText, outputText: output) {
            issues.append("输出删除了原文的先后关系")
        }
        for markers in actionMarkerGroups
            where containsAny(markers, in: sourceText) && !containsAny(markers, in: output) {
            issues.append("输出删除了关键动作：\(markers[0])")
        }
        if changesActiveConfirmationToWaiting(
            sourceText: sourceText,
            outputText: output
        ) {
            issues.append(
                "输出把需要主动执行的确认步骤改成了等待确认；请用“再确认……”或同等主动表述完整保留该步骤"
            )
        }
        for anchor in protectedClaimAnchors(in: sourceText)
            where !output.localizedCaseInsensitiveContains(anchor) {
            issues.append("输出删除了对象或受益人：\(anchor)")
        }

        if let lengthBudget {
            let maximumLength = lengthBudget.maximumCharacters(for: sourceText.count)
            if output.count > maximumLength {
                issues.append("输出扩写超过当前模式的长度预算")
            }
        } else if applicationRole == .messaging {
            let maximumLength = Int(ceil(Double(max(sourceText.count, 1)) * expansionRatio))
                + 12
            if output.count > maximumLength {
                issues.append("聊天消息扩写超过预算")
            }
        }

        if [.development, .aiDevelopmentAssistant].contains(applicationRole) {
            for line in sourceText.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard looksLikeTechnicalLiteral(trimmed), !output.contains(trimmed) else { continue }
                issues.append("代码、命令或路径未逐字保留")
                break
            }
        }

        return FactAuditResult(
            accepted: issues.isEmpty,
            issues: Array(issues.prefix(8)),
            protectedTokens: tokens
        )
    }

    static func protectedTokens(
        in text: String,
        semanticLibraries: Set<SemanticLibraryID> = SemanticLibraryID.defaultEnabled
    ) -> [String] {
        var tokens: [String] = []
        for pattern in protectedPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let token = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty, !tokens.contains(token) { tokens.append(token) }
            }
        }
        for term in SemanticLibraryCatalog.protectedTerms(
            in: text,
            enabled: semanticLibraries
        )
            where !tokens.contains(where: {
                $0.caseInsensitiveCompare(term) == .orderedSame
            }) {
            tokens.append(term)
        }
        return tokens
    }

    private static func containsAny(_ markers: [String], in text: String) -> Bool {
        markers.contains { text.contains($0) }
    }

    private static func isLikelyInformationLoss(
        sourceText: String,
        outputText: String
    ) -> Bool {
        guard !sourceText.isEmpty else { return false }
        return Double(outputText.count + 4) < Double(sourceText.count) * 0.72
    }

    private static func containsResponsibilityAssignment(in text: String) -> Bool {
        let patterns = [
            #"(?:由|让|交给)[\p{Han}A-Za-z0-9_·]{1,12}(?:负责|处理|跟进|完成)"#,
            #"(?:我|我们|他|她|他们)来(?:负责|处理|跟进|完成)"#
        ]
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ) != nil
        }
    }

    private static func changesActiveConfirmationToWaiting(
        sourceText: String,
        outputText: String
    ) -> Bool {
        let sourceActivePattern = #"(?:再|然后|接着|随后)(?:把)?[^，。！？；\n]{0,12}确认"#
        let outputWaitingPattern = #"等[^，。！？；\n]{0,12}确认"#
        let outputActivePattern = #"(?:再|然后|接着|随后)(?:把)?[^，。！？；\n]{0,12}确认"#
        return containsPattern(sourceActivePattern, in: sourceText)
            && containsPattern(outputWaitingPattern, in: outputText)
            && !containsPattern(outputActivePattern, in: outputText)
    }

    private static func containsPattern(_ pattern: String, in text: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    private static func containsExplicitExplanatoryRelation(in text: String) -> Bool {
        containsAny(["所以", "因此", "导致"], in: text)
            || containsPattern(#"原理上[^。！？\n]{0,24}[:：]"#, in: text)
    }

    private static func protectedClaimAnchors(in text: String) -> [String] {
        let patterns = [
            #"(?:给|向|对)([\p{Han}A-Za-z0-9_·]{1,8}(?:客户|用户|同事|老板|领导|供应商|团队|部门|公司|家人|朋友))"#,
            #"把([^，。！？\n]{1,20}?)(?=发送|发给|转发|交付|提供|修改|调整|删除|取消|更新|确认|同步)"#
        ]
        var anchors: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
                let anchor = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !anchor.isEmpty, !anchors.contains(anchor) { anchors.append(anchor) }
            }
        }
        return anchors
    }

    private static func looksLikeTechnicalLiteral(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let standalonePathPattern = #"^(?:~?/|[A-Za-z]:\\)[^\s]+$"#
        let isStandalonePath = (try? NSRegularExpression(
            pattern: standalonePathPattern
        ))?.firstMatch(
            in: line,
            range: NSRange(line.startIndex..<line.endIndex, in: line)
        ) != nil
        return line.hasPrefix("$")
            || line.hasPrefix("git ")
            || line.hasPrefix("swift ")
            || line.hasPrefix("npm ")
            || line.hasPrefix("curl ")
            || isStandalonePath
            || line.hasPrefix("```")
    }
}

enum MessagingRewriteRetryPolicy {
    static let unchangedIssue = "候选仍与原文相同；原文存在可明确处理的表达问题，请逐项修正后给出一版真正改善的成稿。"

    private static let naturallyCompleteShortMessages: Set<String> = [
        "好", "好的", "行", "可以", "收到", "知道了", "明白", "明白了", "没问题",
        "谢谢", "谢谢你", "辛苦了", "嗯", "嗯嗯", "我再看看", "这个方案我再看看"
    ]

    private static let explicitIssueMarkers = [
        "怎么优化", "帮我润色", "优化一下", "润色一下", "修改一下",
        "的的", "进行一个", "来进行", "然后的话", "目的主要是为了",
        "目前来说", "这边的话", "相关的一个", "通讯", "相对来说比较"
    ]

    static func shouldRetryUnchanged(
        sourceText: String,
        candidate: String
    ) -> Bool {
        let source = normalized(sourceText)
        let output = normalized(candidate)
        guard source == output,
              source.count >= 6,
              !isNaturallyCompleteShortMessage(source) else {
            return false
        }
        return !improvementReasons(in: source).isEmpty
    }

    static func isNaturallyCompleteShortMessage(_ text: String) -> Bool {
        let source = normalized(text)
        if naturallyCompleteShortMessages.contains(source) { return true }
        guard let last = source.last,
              "。.!！?？".contains(last) else {
            return false
        }
        let withoutTerminalPunctuation = String(source.dropLast())
        guard withoutTerminalPunctuation.last.map({ !"。.!！?？".contains($0) })
                ?? false else {
            return false
        }
        return naturallyCompleteShortMessages.contains(withoutTerminalPunctuation)
    }

    static func improvementReasons(in sourceText: String) -> [String] {
        let source = normalized(sourceText)
        guard !source.isEmpty else { return [] }

        var reasons: [String] = []
        if explicitIssueMarkers.contains(where: source.contains) {
            reasons.append("存在可修正的搭配、赘余、术语或编辑指令")
        }
        if containsRepeatedPunctuation(in: source) {
            reasons.append("标点存在重复或混用")
        }
        let clauseSeparators = source.filter { "，,；;：:".contains($0) }.count
        if source.count >= 14, clauseSeparators >= 2 {
            reasons.append("多个分句需要检查衔接和节奏")
        } else if source.count >= 28 {
            reasons.append("较长表达需要检查语序和冗余")
        }
        if occurrences(of: "帮我", in: source) >= 2
            || occurrences(of: "然后", in: source) >= 2
            || occurrences(of: "一下", in: source) >= 3 {
            reasons.append("口语成分存在可压缩的机械重复")
        }
        return reasons
    }

    static func containsTrailingEditorInstruction(in text: String) -> Bool {
        let pattern = #"(?:怎么优化|帮我润色|优化一下|润色一下|帮我修改|修改一下)[？?。!！\s]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsRepeatedPunctuation(in text: String) -> Bool {
        let pattern = #"[，,。.!！?？；;：:]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }
}

enum AdaptivePolishIntensity: String, Equatable, Sendable {
    case none
    case light
    case standard
    case strong

    var displayName: String {
        switch self {
        case .none:
            return "无需修改"
        case .light:
            return "轻量"
        case .standard:
            return "标准"
        case .strong:
            return "强力"
        }
    }

    var progressDescription: String {
        switch self {
        case .none:
            return "无需修改"
        case .light:
            return "正在轻度整理…"
        case .standard:
            return "正在标准润色…"
        case .strong:
            return "正在重组表达…"
        }
    }

    var lengthBudget: RewriteLengthBudget? {
        switch self {
        case .none:
            return nil
        case .light:
            return .polish(maximumRatio: 1.25)
        case .standard:
            return .polish(maximumRatio: 1.35)
        case .strong:
            return .polish(maximumRatio: 1.65)
        }
    }
}

struct AdaptivePolishPlan: Equatable, Sendable {
    let intensity: AdaptivePolishIntensity
    let reasons: [String]

    var shouldRequestModel: Bool {
        intensity != .none
    }

    var progressDescription: String {
        intensity.progressDescription
    }

    var lengthBudget: RewriteLengthBudget? {
        intensity.lengthBudget
    }

    var modelInstruction: String {
        let scopeInstruction: String
        switch intensity {
        case .none:
            scopeInstruction = "原文已经完整、自然且可直接使用，必须逐字原样返回。"
        case .light:
            scopeInstruction = """
            优先处理错字、标点、搭配、重复或编辑指令；在保持原意、事实、语气和长度基本不变的前提下，允许做一处能提升清晰度或自然度的小幅改写。复核后若逐项确认原文已经自然、准确且可直接使用，才原样返回。
            """
        case .standard:
            scopeInstruction = """
            处理所有真实表达问题，允许做必要的局部改写、语序调整或拆句，但不要整体换一种说法，也不要扩大原文信息。修改幅度应与问题数量相匹配；复核后只有逐项确认原文已经自然、准确、清楚且可直接使用，才原样返回。
            """
        case .strong:
            scopeInstruction = """
            原文存在较明显的结构或层级问题，可以重排句子、段落和并列项，使逻辑更清楚；仍须完整保留事实、术语、数字、动作顺序、语气和确定程度，不得扩写成原文没有的信息或改成模板化文体。
            """
        }

        let reasonText = reasons.prefix(3).joined(separator: "；")
        let reasonLine = reasonText.isEmpty
            ? ""
            : "\n本地预检依据：\(reasonText)。"
        return """
        当前润色强度：\(intensity.displayName)。
        \(scopeInstruction)\(reasonLine)
        若本段规则与前面的主动改写要求冲突，以本段规定的修改幅度为准。
        """
    }
}

enum AdaptivePolishPolicy {
    static func plan(
        for sourceText: String,
        applicationRole: ApplicationWritingRole
    ) -> AdaptivePolishPlan {
        let source = sourceText.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return AdaptivePolishPlan(
                intensity: .none,
                reasons: ["没有可处理的正文"]
            )
        }

        let paragraphCount = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let separatorCount = source.filter {
            "，,；;：:。！？!?".contains($0)
        }.count
        let issueReasons = MessagingRewriteRetryPolicy.improvementReasons(in: source)

        if shouldUseStrongPolish(
            source: source,
            paragraphCount: paragraphCount,
            separatorCount: separatorCount,
            applicationRole: applicationRole
        ) {
            var reasons = issueReasons
            reasons.append("文本较长或包含多个层级，需要结构整理")
            return AdaptivePolishPlan(
                intensity: .strong,
                reasons: unique(reasons)
            )
        }

        if MessagingRewriteRetryPolicy.isNaturallyCompleteShortMessage(source) {
            return AdaptivePolishPlan(
                intensity: .none,
                reasons: ["自然完整的短回复"]
            )
        }
        if source.count <= 6,
           issueReasons.isEmpty,
           paragraphCount <= 1,
           separatorCount == 0 {
            return AdaptivePolishPlan(
                intensity: .none,
                reasons: ["极短文本未发现明确问题"]
            )
        }

        if !issueReasons.isEmpty {
            let intensity: AdaptivePolishIntensity = source.count <= 18
                && paragraphCount <= 1
                && separatorCount <= 1
                ? .light
                : .standard
            return AdaptivePolishPlan(
                intensity: intensity,
                reasons: unique(issueReasons)
            )
        }

        if source.count <= 18,
           paragraphCount <= 1,
           separatorCount == 0 {
            return AdaptivePolishPlan(
                intensity: .light,
                reasons: ["短文本只需要局部检查"]
            )
        }

        return AdaptivePolishPlan(
            intensity: .standard,
            reasons: ["存在多个表达单元，需要完整检查"]
        )
    }

    private static func shouldUseStrongPolish(
        source: String,
        paragraphCount: Int,
        separatorCount: Int,
        applicationRole: ApplicationWritingRole
    ) -> Bool {
        if ParallelListPolicy.shouldPreferNumberedList(source) { return true }
        if paragraphCount >= 3 || source.count >= 96 { return true }
        if source.count >= 64, separatorCount >= 5 { return true }
        switch applicationRole {
        case .messaging, .document, .email, .generic:
            if source.count >= 48, separatorCount <= 1 { return true }
            if applicationRole == .document || applicationRole == .email {
                return source.count >= 64 && paragraphCount >= 2
            }
            return false
        default:
            return false
        }
    }

    private static func unique(_ reasons: [String]) -> [String] {
        var seen: Set<String> = []
        return reasons.filter { seen.insert($0).inserted }
    }
}

enum RewriteQualityGuard {
    private static let reportStylePhrases = [
        "现将", "现同步", "经沟通确认", "相关事宜", "综上所述", "具体如下",
        "烦请知悉", "请您知悉", "特此说明", "后续将持续", "高度重视"
    ]

    static func audit(
        sourceText: String,
        outputText: String,
        applicationRole: ApplicationWritingRole,
        rewriteMode: RewriteMode = .polish,
        lengthBudget: RewriteLengthBudget? = nil
    ) -> RewriteQualityAuditResult {
        let source = normalized(sourceText)
        let output = normalized(outputText)
        let changed = source != output
        var issues: [String] = []

        if rewriteMode == .polish,
           !changed,
           MessagingRewriteRetryPolicy.shouldRetryUnchanged(
               sourceText: sourceText,
               candidate: outputText
           ) {
            let reasons = MessagingRewriteRetryPolicy.improvementReasons(in: sourceText)
                .prefix(2)
                .joined(separator: "、")
            issues.append(
                reasons.isEmpty
                    ? MessagingRewriteRetryPolicy.unchangedIssue
                    : "候选没有处理原文中的问题：\(reasons)"
            )
        }

        if rewriteMode == .expand,
           ExpansionPolicy.shouldRequireExpansion(source),
           output.count < (lengthBudget ?? .expansion)
               .preferredMinimumCharacters(for: source.count) {
            issues.append(
                "候选没有完成适当扩写，只做了等长改写或压缩；请至少补全一处原文已有的省略成分或紧缩关系，不能只增加语气词、礼貌词或替换近义词"
            )
        }

        if let lengthBudget,
           output.count > lengthBudget.maximumCharacters(for: source.count) {
            issues.append("候选扩写超过当前模式允许的长度")
        }

        if applicationRole == .messaging {
            if MessagingRewriteRetryPolicy.containsTrailingEditorInstruction(in: source),
               MessagingRewriteRetryPolicy.containsTrailingEditorInstruction(in: output) {
                issues.append("输出仍包含面向编辑器的润色要求")
            }
            for phrase in reportStylePhrases
                where output.contains(phrase) && !source.contains(phrase) {
                issues.append("输出引入了工作汇报或公文式表达：\(phrase)")
            }
            if source.count <= 48,
               !source.contains("\n"),
               output.contains("\n"),
               !ParallelListPolicy.shouldPreferNumberedList(source) {
                issues.append("简短聊天被扩写成了分段文本")
            }
            if lengthBudget == nil,
               source.count >= 8,
               output.count > max(source.count + 20, Int(Double(source.count) * 1.65)) {
                issues.append("聊天结果扩写过多，不像原有表达节奏")
            }
        }

        if ParallelListPolicy.shouldPreferNumberedList(source),
           !ParallelListPolicy.containsNumberedList(output) {
            issues.append("原文包含至少三个明确的并列项；请使用“1、2、3……”逐条换行列出")
        }

        return RewriteQualityAuditResult(
            accepted: issues.isEmpty,
            issues: Array(issues.prefix(3)),
            meaningfullyChanged: changed
        )
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RewriteAlignmentGuard {
    static func audit(
        sourceText: String,
        outputText: String,
        applicationRole: ApplicationWritingRole,
        rewriteMode: RewriteMode = .polish,
        lengthBudget: RewriteLengthBudget? = nil
    ) -> RewriteAlignmentAuditResult {
        let source = contentCharacters(in: sourceText)
        let output = contentCharacters(in: outputText)
        guard source.count >= 12, !output.isEmpty, source != output else {
            return RewriteAlignmentAuditResult(
                accepted: true,
                issues: [],
                retainedSourceRatio: 1,
                introducedOutputRatio: 0
            )
        }

        let retainedCount = multisetIntersectionCount(source, output)
        let retainedSourceRatio = Double(retainedCount) / Double(source.count)
        let introducedOutputRatio = 1 - Double(retainedCount) / Double(output.count)
        let outputLengthRatio = Double(output.count) / Double(source.count)
        let minimumRetention = applicationRole == .messaging ? 0.46 : 0.38
        let allowsConciseCleanup = applicationRole == .messaging
            && !MessagingRewriteRetryPolicy.improvementReasons(in: sourceText).isEmpty
            && retainedSourceRatio >= 0.45
        var issues: [String] = []

        if retainedSourceRatio < minimumRetention,
           introducedOutputRatio > 0.52 {
            issues.append("输出与原文的词句对齐度过低，可能存在无依据的大幅改写")
        }
        if source.count >= 18,
           outputLengthRatio < 0.55,
           retainedSourceRatio < 0.66,
           !allowsConciseCleanup {
            issues.append("输出大幅压缩了原文，可能删除了必要信息")
        }
        let excessiveExpansionRatio = rewriteMode == .expand ? 2.15 : 1.85
        let excessiveIntroductionRatio = rewriteMode == .expand ? 0.58 : 0.42
        let exceedsExplicitBudget = lengthBudget.map {
            outputText.count > $0.maximumCharacters(for: sourceText.count)
        } ?? false
        if (outputLengthRatio > excessiveExpansionRatio || exceedsExplicitBudget),
           introducedOutputRatio > excessiveIntroductionRatio {
            issues.append("输出大幅扩写了原文，可能增加了无依据内容")
        }

        return RewriteAlignmentAuditResult(
            accepted: issues.isEmpty,
            issues: Array(issues.prefix(3)),
            retainedSourceRatio: retainedSourceRatio,
            introducedOutputRatio: introducedOutputRatio
        )
    }

    private static func contentCharacters(in text: String) -> [Character] {
        text.precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_CN")
            )
            .filter { character in
                character.unicodeScalars.contains {
                    CharacterSet.alphanumerics.contains($0)
                }
            }
    }

    private static func multisetIntersectionCount(
        _ source: [Character],
        _ output: [Character]
    ) -> Int {
        var remaining = output.reduce(into: [Character: Int]()) { counts, character in
            counts[character, default: 0] += 1
        }
        var retained = 0
        for character in source where remaining[character, default: 0] > 0 {
            retained += 1
            remaining[character, default: 0] -= 1
        }
        return retained
    }
}

enum VoiceGuard {
    private static let formalPhrases = [
        "尊敬的", "感谢您的理解与支持", "我们高度重视", "诚挚感谢", "非常荣幸",
        "敬请知悉", "烦请知悉", "特此说明", "后续将持续推进", "综上所述",
        "现将", "现同步", "具体如下"
    ]

    static func audit(
        sourceText: String,
        outputText: String,
        expectedVoice: VoiceMetrics,
        applicationRole: ApplicationWritingRole
    ) -> VoiceAuditResult {
        var issues: [String] = []
        let sourceMetrics = VoiceAnalyzer.metrics(from: [sourceText])
        let outputMetrics = VoiceAnalyzer.metrics(from: [outputText])

        if formalPhrases.contains(where: { outputText.contains($0) && !sourceText.contains($0) }) {
            issues.append("输出出现模板化正式话术")
        }
        if applicationRole == .messaging,
           outputMetrics.formality > max(expectedVoice.formality + 0.30, sourceMetrics.formality + 0.35) {
            issues.append("输出明显比用户风格正式")
        }
        if expectedVoice.emojiRate < 0.01,
           outputText.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }),
           !sourceText.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
            issues.append("输出擅自增加表情")
        }
        if applicationRole == .messaging,
           sourceText.count >= 8,
           outputText.count > sourceText.count * 2 {
            issues.append("输出不像原有的简短聊天节奏")
        }
        return VoiceAuditResult(accepted: issues.isEmpty, issues: issues)
    }
}

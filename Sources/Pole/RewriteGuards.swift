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
        intent = try container.decodeIfPresent(CommunicationIntent.self, forKey: .intent) ?? .unknown
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

enum RewriteSafetyError: LocalizedError {
    case rejected([String])

    var errorDescription: String? {
        switch self {
        case .rejected(let issues):
            let detail = issues.prefix(2).joined(separator: "；")
            return detail.isEmpty
                ? "候选结果未通过本地事实与声音检查"
                : "候选结果未通过安全检查：\(detail)"
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
    private static let sequenceMarkerGroups = [
        ["先", "首先"], ["再", "然后", "随后"], ["之前", "以前"], ["之后", "以后"]
    ]
    private static let actionMarkerGroups = [
        ["发送", "发给", "转发"],
        ["确认", "核实"],
        ["通知", "告知", "同步"],
        ["提交", "交付", "提供"],
        ["修改", "调整", "更新"],
        ["删除", "移除", "取消"],
        ["付款", "支付", "打款"],
        ["安排", "预约", "排期"],
        ["完成", "做完"],
        ["拒绝", "不同意"],
        ["回复", "答复", "反馈"]
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
        expansionRatio: Double
    ) -> FactAuditResult {
        let output = result.rewrittenText
        var issues: [String] = []
        let tokens = protectedTokens(in: sourceText)
        for token in tokens where !output.localizedCaseInsensitiveContains(token) {
            issues.append("缺少受保护内容：\(token)")
        }

        if !result.addedClaims.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).isEmpty {
            issues.append("模型报告存在新增事实")
        }
        if !result.certaintyChanges.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).isEmpty {
            issues.append("模型报告存在确定性变化")
        }

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
            issues.append("输出擅自增加\(introduction.label)信息")
        }
        if !containsResponsibilityAssignment(in: sourceText), containsResponsibilityAssignment(in: output) {
            issues.append("输出擅自增加责任人或任务分配")
        }

        for markers in sequenceMarkerGroups
            where containsAny(markers, in: sourceText) && !containsAny(markers, in: output) {
            issues.append("输出删除了原文的先后关系")
        }
        for markers in actionMarkerGroups
            where containsAny(markers, in: sourceText) && !containsAny(markers, in: output) {
            issues.append("输出删除了关键动作：\(markers[0])")
        }
        for anchor in protectedClaimAnchors(in: sourceText)
            where !output.localizedCaseInsensitiveContains(anchor) {
            issues.append("输出删除了对象或受益人：\(anchor)")
        }

        if applicationRole == .messaging {
            let maximumLength = Int(ceil(Double(max(sourceText.count, 1)) * expansionRatio)) + 12
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

    static func protectedTokens(in text: String) -> [String] {
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
        return tokens
    }

    private static func containsAny(_ markers: [String], in text: String) -> Bool {
        markers.contains { text.contains($0) }
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
        return line.hasPrefix("$")
            || line.hasPrefix("git ")
            || line.hasPrefix("swift ")
            || line.hasPrefix("npm ")
            || line.hasPrefix("curl ")
            || line.contains("/") && !line.contains(" ")
            || line.hasPrefix("```")
    }
}

enum VoiceGuard {
    private static let formalPhrases = [
        "尊敬的", "感谢您的理解与支持", "我们高度重视", "诚挚感谢", "非常荣幸",
        "敬请知悉", "特此说明", "后续将持续推进"
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

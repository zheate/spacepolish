import Foundation

package enum RecentQuestionType: String, Codable, Equatable, Sendable {
    case feasibility
    case status
    case reason
    case timing
    case action
    case confirmation
    case unknown
}

struct RecentConversationContext: Equatable, Sendable {
    let questionType: RecentQuestionType
    let confidence: Double

    static let empty = RecentConversationContext(
        questionType: .unknown,
        confidence: 0
    )
}

enum ExpansionOperation: String, Hashable, Sendable {
    case completeEllipsis
    case connectClauses
    case clarifyReference
    case splitSentence
    case organizeParallelItems
}

struct ContextualExpansionPlan: Equatable, Sendable {
    let operations: Set<ExpansionOperation>
    let questionType: RecentQuestionType
    let applicationRole: ApplicationWritingRole
    let relationshipRole: ConversationRole?
    let lengthBudget: RewriteLengthBudget
    let requiresVisibleExpansion: Bool

    var modelInstruction: String {
        var lines = [
            "本次是根据当前沟通场景进行适当扩写。",
            "上下文只能决定表达顺序、完整程度和口吻，不能成为新增事实的来源。",
            "不得增加原文没有的原因、时间、数据、承诺、责任人、行动、下一步或结论。",
            "当前应用场景：\(applicationRole.displayName)。"
        ]

        if let relationshipRole {
            lines.append("沟通对象类别：\(relationshipRole.displayName)。")
            lines.append(relationshipInstruction(for: relationshipRole))
        }

        switch questionType {
        case .feasibility:
            lines.append("当前对话倾向于询问可行性。优先表达原文已有判断，再说明原文已经给出的验证条件。")
        case .status:
            lines.append("当前对话倾向于询问进展。优先说明当前状态，再整理原文已有的未确定条件。")
        case .reason:
            lines.append("当前对话倾向于询问原因。只有原文已经提供原因时才整理因果关系，不能自行推断。")
        case .timing:
            lines.append("当前对话倾向于询问时间。原文没有时间信息时，禁止添加日期、周期或预计时间。")
        case .action:
            lines.append("当前对话倾向于询问处理方式。完整保留原文已有动作、对象和先后顺序，不增加下一步。")
        case .confirmation:
            lines.append("当前对话倾向于确认信息。明确区分已确认、未确认和需要验证，不能改变确定程度。")
        case .unknown:
            break
        }

        if operations.contains(.completeEllipsis) {
            lines.append("可以补全原文明确支持的省略成分，但不能借补全引入新的事实或动作。")
        }
        if operations.contains(.connectClauses) {
            lines.append("补全原文已经明确支持的逻辑连接和先后关系。")
        }
        if operations.contains(.clarifyReference) {
            lines.append("只在原文内的指代对象唯一且明确时补全指代，否则保留原表达。")
        }
        if operations.contains(.splitSentence) {
            lines.append("原文较长或分句较多时，可以拆句改善阅读，但不得改变信息层级。")
        }
        if operations.contains(.organizeParallelItems) {
            lines.append("三个及以上明确同层级事项使用编号逐条列出。")
        }

        if !requiresVisibleExpansion {
            lines.append("原文属于无需安全扩写的短回复或完整短句，允许逐字保持原文。")
        }

        return lines.joined(separator: "\n")
    }

    private func relationshipInstruction(for role: ConversationRole) -> String {
        switch role {
        case .manager:
            return "表达策略：尊重、直接地说清原文已有状态或判断，不改成工作汇报，不增加解释或承诺。"
        case .customer:
            return "表达策略：保留技术事实并减少口语省略造成的误解，不增加承诺、时间或客服模板话术。"
        case .colleague:
            return "表达策略：自然、直接、便于协作，不增加原文没有的任务、配合要求或下一步。"
        case .friendOrFamily:
            return "表达策略：保留日常聊天节奏和亲疏程度，不刻意正式化、解释或增加客套话。"
        case .custom:
            return "表达策略：保持原文口吻，只调整完整程度和组织方式，不扩展事实边界。"
        }
    }
}

enum RecentConversationAnalyzer {
    static func analyze(messages: [ConversationMessage]) -> RecentConversationContext {
        guard let text = messages.reversed()
            .first(where: { $0.direction == .received })?
            .usableText else {
            return .empty
        }

        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rules: [(RecentQuestionType, [String])] = [
            (.timing, ["什么时候", "多久", "哪天", "交期", "时间", "when"]),
            (.reason, ["为什么", "什么原因", "原因是", "怎么回事", "why"]),
            (.feasibility, ["能不能", "可以吗", "能做到吗", "是否可行", "可不可以"]),
            (.status, ["怎么样了", "进展", "现在什么情况", "目前情况", "做到哪了"]),
            (.action, ["怎么处理", "怎么办", "需要做什么", "下一步"]),
            (.confirmation, ["确认了吗", "确定了吗", "是否确认", "有没有确认"])
        ]

        for (type, markers) in rules where markers.contains(where: normalized.contains) {
            return RecentConversationContext(questionType: type, confidence: 0.9)
        }
        return .empty
    }
}

enum ContextualExpansionPlanner {
    static func plan(
        sourceText: String,
        communicationContext: CommunicationContext,
        recentContext: RecentConversationContext
    ) -> ContextualExpansionPlan {
        let source = normalize(sourceText)
        var operations: Set<ExpansionOperation> = []
        let clauseSeparators = source.filter { "，,；;：:。！？!?".contains($0) }.count

        if source.count >= 10, clauseSeparators >= 1 {
            operations.insert(.connectClauses)
        }
        if containsAmbiguousReference(source) {
            operations.insert(.clarifyReference)
        }
        if source.count >= 28 || clauseSeparators >= 3 {
            operations.insert(.splitSentence)
        }
        if ParallelListPolicy.shouldPreferNumberedList(source) {
            operations.insert(.organizeParallelItems)
        }
        if ExpansionPolicy.shouldRequireExpansion(source) {
            operations.insert(.completeEllipsis)
        }

        let isSafeNoOp = MessagingRewriteRetryPolicy
            .isNaturallyCompleteShortMessage(source)
            || source.count < 8
        let hasRequiredExpansionOperation = operations.contains(.completeEllipsis)
            || operations.contains(.organizeParallelItems)

        return ContextualExpansionPlan(
            operations: operations,
            questionType: recentContext.confidence >= 0.8
                ? recentContext.questionType
                : .unknown,
            applicationRole: communicationContext.applicationContext.role,
            relationshipRole: communicationContext.relationship?.role
                ?? communicationContext.policy.relationshipRole,
            lengthBudget: .expansion,
            requiresVisibleExpansion: !isSafeNoOp && hasRequiredExpansionOperation
        )
    }

    private static func containsAmbiguousReference(_ text: String) -> Bool {
        ["这个", "那个", "这块", "这边", "它", "上述", "前面那个"]
            .contains(where: text.contains)
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ContextualExpansionAuditResult: Equatable, Sendable {
    let accepted: Bool
    let issues: [String]
    let evidence: [String]
}

enum ContextualExpansionGuard {
    static func audit(
        sourceText: String,
        outputText: String,
        plan: ContextualExpansionPlan
    ) -> ContextualExpansionAuditResult {
        let source = normalize(sourceText)
        let output = normalize(outputText)
        var evidence: [String] = []
        var issues: [String] = []

        if plan.requiresVisibleExpansion {
            let minimum = plan.lengthBudget.preferredMinimumCharacters(for: source.count)
            if output.count < minimum {
                issues.append("候选没有达到可感知扩写幅度")
            }
        }

        if plan.operations.contains(.connectClauses),
           hasImprovedStructure(source: source, output: output) {
            evidence.append("补全了分句关系")
        }
        if plan.operations.contains(.organizeParallelItems),
           ParallelListPolicy.containsNumberedList(output) {
            evidence.append("整理了并列层级")
        }
        if plan.operations.contains(.splitSentence),
           sentenceBoundaryCount(output) > sentenceBoundaryCount(source) {
            evidence.append("改善了长句结构")
        }

        if plan.requiresVisibleExpansion,
           source != output,
           evidence.isEmpty,
           output.count <= source.count + 2 {
            issues.append("候选只做了近义词或语气词替换，没有完成结构性补全")
        }

        return ContextualExpansionAuditResult(
            accepted: issues.isEmpty,
            issues: Array(issues.prefix(3)),
            evidence: evidence
        )
    }

    private static func hasImprovedStructure(source: String, output: String) -> Bool {
        sentenceBoundaryCount(output) > sentenceBoundaryCount(source)
            || connectorCount(output) > connectorCount(source)
    }

    private static func sentenceBoundaryCount(_ text: String) -> Int {
        text.filter { "。！？!?；;".contains($0) }.count
    }

    private static func connectorCount(_ text: String) -> Int {
        let connectors = [
            "然后", "之后", "完成后", "确认后", "因此", "但是", "同时", "再根据"
        ]
        return connectors.reduce(0) { partial, connector in
            partial + text.components(separatedBy: connector).count - 1
        }
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor RecentContextCache {
    struct Entry: Sendable {
        let context: RecentConversationContext
        let expiresAt: Date
    }

    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]

    init(lifetime: TimeInterval = 120) {
        self.lifetime = lifetime
    }

    func context(for key: String, now: Date = Date()) -> RecentConversationContext? {
        guard let entry = entries[key], entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.context
    }

    func save(_ context: RecentConversationContext, for key: String, now: Date = Date()) {
        entries[key] = Entry(
            context: context,
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }
}

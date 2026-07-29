import Combine
import CryptoKit
import Foundation

enum CommunicationIntent: String, Codable, CaseIterable, Equatable {
    case inform
    case request
    case apologize
    case persuade
    case negotiate
    case reject
    case thank
    case complain
    case casual
    case unknown
}

enum ConversationMessageDirection: String, Codable, Equatable {
    case sent
    case received
}

enum ConversationMessageKind: String, Codable, Equatable {
    case text
    case image
    case file
    case system
    case recalled
    case other
}

struct ConversationMessage: Codable, Equatable, Identifiable {
    let id: String
    let conversationID: String
    let timestamp: Date
    let direction: ConversationMessageDirection
    let senderID: String?
    let kind: ConversationMessageKind
    let text: String?

    var usableText: String? {
        guard kind == .text, let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RoleProbabilities: Codable, Equatable {
    var manager: Double = 0
    var customer: Double = 0
    var colleague: Double = 0
    var friendOrFamily: Double = 0
    var custom: Double = 0

    subscript(role: ConversationRole) -> Double {
        get {
            switch role {
            case .manager: return manager
            case .customer: return customer
            case .colleague: return colleague
            case .friendOrFamily: return friendOrFamily
            case .custom: return custom
            }
        }
        set {
            switch role {
            case .manager: manager = newValue
            case .customer: customer = newValue
            case .colleague: colleague = newValue
            case .friendOrFamily: friendOrFamily = newValue
            case .custom: custom = newValue
            }
        }
    }

    var mostLikely: (role: ConversationRole, probability: Double) {
        ConversationRole.allCases
            .map { ($0, self[$0]) }
            .max { $0.1 < $1.1 } ?? (.custom, 0)
    }
}

struct RelationshipDimensions: Codable, Equatable {
    var powerDistance: Double
    var familiarity: Double
    var formality: Double
    var directness: Double
    var detail: Double

    static func defaults(for role: ConversationRole) -> Self {
        switch role {
        case .manager:
            return .init(powerDistance: 0.80, familiarity: 0.45, formality: 0.68, directness: 0.72, detail: 0.50)
        case .customer:
            return .init(powerDistance: 0.55, familiarity: 0.28, formality: 0.76, directness: 0.58, detail: 0.58)
        case .colleague:
            return .init(powerDistance: 0.25, familiarity: 0.62, formality: 0.42, directness: 0.74, detail: 0.48)
        case .friendOrFamily:
            return .init(powerDistance: 0.05, familiarity: 0.92, formality: 0.12, directness: 0.84, detail: 0.36)
        case .custom:
            return .init(powerDistance: 0.30, familiarity: 0.50, formality: 0.48, directness: 0.65, detail: 0.50)
        }
    }
}

struct PendingRelationshipChange: Codable, Equatable {
    var proposedRole: ConversationRole
    var probability: Double
    var observationCount: Int
    var evidence: [String]
    var firstObservedAt: Date
}

struct RelationshipProfile: Codable, Equatable, Identifiable {
    let id: UUID
    let applicationIdentifier: String
    var conversationID: String?
    var conversationTitle: String
    var role: ConversationRole
    var probabilities: RoleProbabilities
    var confidence: Double
    var evidence: [String]
    var dimensions: RelationshipDimensions
    var customInstruction: String
    var lastAnalyzedAt: Date?
    var pendingChange: PendingRelationshipChange?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        applicationIdentifier: String,
        conversationID: String? = nil,
        conversationTitle: String,
        role: ConversationRole,
        probabilities: RoleProbabilities? = nil,
        confidence: Double = 1,
        evidence: [String] = ["用户手动确认"],
        dimensions: RelationshipDimensions? = nil,
        customInstruction: String? = nil,
        lastAnalyzedAt: Date? = nil,
        pendingChange: PendingRelationshipChange? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.applicationIdentifier = applicationIdentifier
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
        var resolvedProbabilities = probabilities ?? RoleProbabilities()
        if probabilities == nil { resolvedProbabilities[role] = confidence }
        self.probabilities = resolvedProbabilities
        self.confidence = confidence
        self.evidence = Array(evidence.prefix(5))
        self.dimensions = dimensions ?? .defaults(for: role)
        self.customInstruction = role.resolvedInstruction(
            from: customInstruction ?? role.defaultInstruction
        )
        self.lastAnalyzedAt = lastAnalyzedAt
        self.pendingChange = pendingChange
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var normalizedTitle: String? {
        ConversationTitleNormalizer.normalize(conversationTitle)
    }

    func matches(_ snapshot: ConversationSnapshot) -> Bool {
        applicationIdentifier == snapshot.applicationIdentifier
            && normalizedTitle != nil
            && normalizedTitle == snapshot.normalizedTitle
    }

    func anonymizedInstruction() -> String {
        var instruction = role.resolvedInstruction(from: customInstruction)
        for candidate in [conversationTitle, conversationTitle.replacingOccurrences(of: " ", with: "")] {
            guard !candidate.isEmpty else { continue }
            instruction = instruction.replacingOccurrences(
                of: candidate,
                with: "对方",
                options: [.caseInsensitive]
            )
        }
        return instruction
    }
}

struct VoiceMetrics: Codable, Equatable {
    var averageSentenceLength: Double = 18
    var emojiRate: Double = 0
    var exclamationRate: Double = 0
    var formality: Double = 0.45
    var directness: Double = 0.65
    var detail: Double = 0.50
    var styleMarkers: [String] = []
}

struct VoiceOverlay: Codable, Equatable {
    var relationshipID: UUID
    var sampleCount: Int
    var metrics: VoiceMetrics
    var updatedAt: Date
}

struct VoiceProfile: Codable, Equatable {
    var sampleCount: Int = 0
    var metrics = VoiceMetrics()
    var relationshipOverlays: [VoiceOverlay] = []
    var updatedAt: Date?

    func metrics(for relationshipID: UUID?) -> VoiceMetrics {
        guard let relationshipID,
              let overlay = relationshipOverlays.first(where: { $0.relationshipID == relationshipID }),
              overlay.sampleCount >= 3 else {
            return metrics
        }
        return VoiceAnalyzer.blend(metrics, overlay.metrics, overlayWeight: 0.65)
    }

    func sampleCount(for relationshipID: UUID?) -> Int {
        guard let relationshipID,
              let overlay = relationshipOverlays.first(where: { $0.relationshipID == relationshipID }),
              overlay.sampleCount >= 3 else {
            return sampleCount
        }
        return overlay.sampleCount
    }
}

enum RewriteFeedback: String, Codable, CaseIterable {
    case good
    case tooFormal
    case tooVerbose
    case notMyVoice
    case factIncorrect

    var displayName: String {
        switch self {
        case .good: return "符合"
        case .tooFormal: return "太正式"
        case .tooVerbose: return "太啰嗦"
        case .notMyVoice: return "不像我"
        case .factIncorrect: return "事实有误"
        }
    }
}

struct PendingRewriteSample: Codable, Equatable, Identifiable {
    let id: UUID
    let relationshipID: UUID?
    let conversationID: String?
    let fingerprint: UInt64
    let generatedVoice: VoiceMetrics
    let createdAt: Date

    init(
        id: UUID = UUID(),
        relationshipID: UUID?,
        conversationID: String?,
        rewrittenText: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.relationshipID = relationshipID
        self.conversationID = conversationID
        self.fingerprint = TextFingerprint.make(rewrittenText)
        self.generatedVoice = VoiceAnalyzer.metrics(from: [rewrittenText])
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, relationshipID, conversationID, fingerprint, generatedVoice, createdAt, rewrittenText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        relationshipID = try container.decodeIfPresent(UUID.self, forKey: .relationshipID)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let savedFingerprint = try container.decodeIfPresent(UInt64.self, forKey: .fingerprint) {
            fingerprint = savedFingerprint
            generatedVoice = try container.decodeIfPresent(VoiceMetrics.self, forKey: .generatedVoice)
                ?? VoiceMetrics()
        } else {
            let legacyText = try container.decodeIfPresent(String.self, forKey: .rewrittenText) ?? ""
            fingerprint = TextFingerprint.make(legacyText)
            generatedVoice = VoiceAnalyzer.metrics(from: [legacyText])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(relationshipID, forKey: .relationshipID)
        try container.encodeIfPresent(conversationID, forKey: .conversationID)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(generatedVoice, forKey: .generatedVoice)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

struct RewriteHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let sourceText: String
    let rewrittenText: String
    let applicationRole: ApplicationWritingRole
    let relationshipID: UUID?
    let createdAt: Date
    var feedback: RewriteFeedback?

    init(
        id: UUID = UUID(),
        sourceText: String,
        rewrittenText: String,
        applicationRole: ApplicationWritingRole,
        relationshipID: UUID?,
        createdAt: Date = Date(),
        feedback: RewriteFeedback? = nil
    ) {
        self.id = id
        self.sourceText = sourceText
        self.rewrittenText = rewrittenText
        self.applicationRole = applicationRole
        self.relationshipID = relationshipID
        self.createdAt = createdAt
        self.feedback = feedback
    }

    var changed: Bool { sourceText != rewrittenText }
}

enum RewriteHistoryPolicy {
    static let maximumEntries = 200
    static let retentionInterval: TimeInterval = 180 * 86_400

    static func retained(
        _ entries: [RewriteHistoryEntry],
        now: Date = Date()
    ) -> [RewriteHistoryEntry] {
        Array(
            entries
                .filter { now.timeIntervalSince($0.createdAt) <= retentionInterval }
                .sorted { $0.createdAt < $1.createdAt }
                .suffix(maximumEntries)
        )
    }

    static func learnedMetrics(sourceText: String, rewrittenText: String) -> VoiceMetrics {
        let source = VoiceAnalyzer.metrics(from: [sourceText])
        let rewritten = VoiceAnalyzer.metrics(from: [rewrittenText])
        // The user's draft is the strongest identity signal. The accepted
        // rewrite contributes only enough weight to capture useful cleanup.
        return VoiceAnalyzer.blend(rewritten, source, overlayWeight: 0.72)
    }
}

struct SafetyPreferences: Codable, Equatable {
    var factIssueCount: Int = 0
    var preferredExpansionRatio: Double = 1.35
}

struct CommunicationPolicy: Codable, Equatable {
    let intent: CommunicationIntent
    let relationshipRole: ConversationRole?
    let relationshipConfidence: Double
    let dimensions: RelationshipDimensions?
    let voice: VoiceMetrics
    let voiceSampleCount: Int
    let customInstruction: String?
    let messageExpansionRatio: Double

    var modelInstruction: String {
        var lines = [
            "优先做小而有效的修改：有明确的清晰度、准确性或自然度提升空间时，至少完成一处具体改进；只有原文已经自然准确时才保持不变，不要做无意义的同义替换。",
            "保持用户原有的短句、分句、标点和自然口吻，让结果像用户本人更成熟的一版，而不是换成另一种人格。",
            "禁止补充原文没有的事实、原因、时间、承诺、行动、责任人或结论。"
        ]
        if intent != .unknown {
            lines.append("当前沟通意图：\(intent.rawValue)。只调整表达策略，不得改变意图本身。")
        }
        if let relationshipRole, let dimensions {
            lines.append("沟通关系类别：\(relationshipRole.displayName)；关系判断置信度 \(String(format: "%.2f", relationshipConfidence))。")
            lines.append(String(format: "关系策略：权力距离 %.2f，熟悉度 %.2f，礼貌不等于正式。", dimensions.powerDistance, dimensions.familiarity))
        }
        if !voice.styleMarkers.isEmpty {
            lines.append("可保留的用户语气习惯：\(voice.styleMarkers.prefix(6).joined(separator: "、"))。")
        }
        if voiceSampleCount > 0 {
            let sentencePreference: String
            if voice.averageSentenceLength < 14 {
                sentencePreference = "偏短句"
            } else if voice.averageSentenceLength > 28 {
                sentencePreference = "允许稍完整的长句"
            } else {
                sentencePreference = "中等句长"
            }
            let tonePreference = voice.formality < 0.38
                ? "日常口语，不要正式化"
                : (voice.formality > 0.62 ? "稍正式但不写成公文" : "自然、克制")
            let directPreference = voice.directness > 0.68
                ? "倾向直接表达"
                : "保留适度缓和"
            lines.append(
                "本地个人画像摘要：\(sentencePreference)，\(tonePreference)，\(directPreference)。只模仿稳定风格，不复用历史中的事实或具体内容。"
            )
        }
        if let customInstruction,
           !customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(customInstruction)
        }
        return lines.joined(separator: "\n")
    }
}

enum CommunicationIntentAnalyzer {
    static func infer(from text: String) -> CommunicationIntent {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .unknown }
        let rules: [(CommunicationIntent, [String])] = [
            (.apologize, ["抱歉", "对不起", "不好意思", "sorry"]),
            (.thank, ["谢谢", "感谢", "辛苦了", "thanks", "thank you"]),
            (.reject, ["不能", "不行", "没办法", "不接受", "拒绝", "无法同意"]),
            (.negotiate, ["能否", "是否可以", "商量", "折中", "报价", "条件"]),
            (.request, ["请", "麻烦", "帮我", "能不能", "可以帮", "烦请"]),
            (.persuade, ["建议", "最好", "更合适", "推荐", "应该选择"]),
            (.complain, ["投诉", "不满意", "太差", "一直没有", "怎么还"]),
            (.inform, ["同步", "通知", "进展", "目前", "已经", "预计"]),
            (.casual, ["哈哈", "吃饭", "晚安", "周末", "在吗"])
        ]
        return rules.first(where: { rule in rule.1.contains(where: normalized.contains) })?.0 ?? .unknown
    }
}

struct CommunicationContext: Equatable {
    let applicationContext: ApplicationContext
    let conversationSnapshot: ConversationSnapshot?
    let relationship: RelationshipProfile?
    let intent: CommunicationIntent
    let voice: VoiceProfile
    let policy: CommunicationPolicy
    let dataConfidence: Double
}

struct RelationshipAnalysis: Equatable {
    let role: ConversationRole
    let probabilities: RoleProbabilities
    let confidence: Double
    let evidence: [String]
    let dimensions: RelationshipDimensions
}

enum RelationshipAnalyzer {
    static func analyze(title: String?, messages: [ConversationMessage]) -> RelationshipAnalysis {
        var scores = RoleProbabilities(
            manager: 0.12,
            customer: 0.12,
            colleague: 0.16,
            friendOrFamily: 0.16,
            custom: 0.08
        )
        var evidence: [String] = []

        let titleInferredRole = ConversationRoleInference.infer(from: title)
        if let inferred = titleInferredRole {
            scores[inferred] += 1.4
            evidence.append("会话称谓具有明确关系含义")
        }

        let usable = messages.compactMap { message -> (ConversationMessageDirection, String)? in
            message.usableText.map { (message.direction, $0.lowercased()) }
        }
        let sent = usable.filter { $0.0 == .sent }.map { $0.1 }
        let received = usable.filter { $0.0 == .received }.map { $0.1 }
        let all = usable.map { $0.1 }.joined(separator: "\n")

        let businessTerms = ["项目", "需求", "交付", "合同", "报价", "方案", "进度", "排期", "上线"]
        let customerTerms = ["贵司", "客户", "报价", "合同", "合作", "交付"]
        let managerReplyTerms = ["收到", "好的", "我调整", "我同步", "汇报", "进展"]
        let directiveTerms = ["你来", "你把", "改一下", "再看", "什么时候完成", "尽快"]
        let friendTerms = ["哈哈", "笑死", "宝贝", "亲爱的", "吃饭", "周末", "晚安"]

        if countMatches(businessTerms, in: all) >= 3 {
            scores.customer += 0.30
            scores.colleague += 0.38
            scores.manager += 0.28
            evidence.append("对话长期包含工作事务主题")
        }
        if countMatches(customerTerms, in: all) >= 2 {
            scores.customer += 0.65
            evidence.append("对话包含客户、合同或交付语境")
        }
        if sent.reduce(0, { $0 + countMatches(managerReplyTerms, in: $1) }) >= 3,
           received.reduce(0, { $0 + countMatches(directiveTerms, in: $1) }) >= 2 {
            scores.manager += 0.85
            evidence.append("双方互动呈现汇报与决策关系")
        }
        if all.contains("我们") || all.contains("一起") || all.contains("联调") {
            scores.colleague += 0.42
            evidence.append("对话呈现平等协作模式")
        }
        if countMatches(friendTerms, in: all) >= 3 || emojiCount(in: all) >= 5 {
            scores.friendOrFamily += 0.82
            evidence.append("对话具有稳定的亲密或休闲表达")
        }

        let total = ConversationRole.allCases.reduce(0.0) { $0 + max(scores[$1], 0) }
        if total > 0 {
            for role in ConversationRole.allCases { scores[role] = scores[role] / total }
        }
        let likely = scores.mostLikely
        let dataFactor = min(1, Double(usable.count) / 20)
        let evidenceConfidence = likely.probability * (0.72 + dataFactor * 0.28)
        let confidence = min(
            0.98,
            titleInferredRole == likely.role ? max(0.86, evidenceConfidence) : evidenceConfidence
        )
        var dimensions = RelationshipDimensions.defaults(for: likely.role)
        if !sent.isEmpty {
            let learned = VoiceAnalyzer.metrics(from: sent)
            dimensions.formality = learned.formality
            dimensions.directness = learned.directness
            dimensions.detail = learned.detail
        }
        return RelationshipAnalysis(
            role: likely.role,
            probabilities: scores,
            confidence: confidence,
            evidence: evidence.isEmpty ? ["当前证据不足，保留手动确认"] : Array(evidence.prefix(5)),
            dimensions: dimensions
        )
    }

    private static func countMatches(_ terms: [String], in text: String) -> Int {
        terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }

    private static func emojiCount(in text: String) -> Int {
        text.unicodeScalars.filter { $0.properties.isEmojiPresentation }.count
    }
}

enum VoiceAnalyzer {
    private static let formalMarkers = ["您好", "贵司", "感谢您的", "敬请", "烦请", "特此", "诚挚", "荣幸"]
    private static let directMarkers = ["直接", "先", "需要", "请", "麻烦", "帮我", "确认", "同步", "推进"]
    private static let detailMarkers = ["因为", "所以", "具体", "主要", "包括", "例如", "分别"]
    private static let allowedStyleMarkers = [
        "嗯", "好的", "收到", "麻烦", "帮我", "辛苦", "谢谢", "哈哈", "哈", "行", "可以",
        "同步", "确认", "推进", "先", "再", "一下", "这边", "我觉得", "建议"
    ]

    static func metrics(from texts: [String]) -> VoiceMetrics {
        let clean = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return VoiceMetrics() }
        let characters = clean.reduce(0) { $0 + $1.count }
        let sentences = clean.reduce(0) { result, text in
            result + max(1, text.filter { "。！？!?\n".contains($0) }.count)
        }
        let emoji = clean.reduce(0) { $0 + $1.unicodeScalars.filter { $0.properties.isEmojiPresentation }.count }
        let exclamations = clean.reduce(0) { $0 + $1.filter { "！!".contains($0) }.count }
        let joined = clean.joined(separator: "\n")
        let formal = normalizedMarkerScore(formalMarkers, in: joined)
        let direct = normalizedMarkerScore(directMarkers, in: joined)
        let detail = normalizedMarkerScore(detailMarkers, in: joined)
        let markers = allowedStyleMarkers
            .map { ($0, joined.components(separatedBy: $0).count - 1) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map(\.0)
        return VoiceMetrics(
            averageSentenceLength: Double(characters) / Double(max(sentences, 1)),
            emojiRate: Double(emoji) / Double(max(characters, 1)),
            exclamationRate: Double(exclamations) / Double(max(characters, 1)),
            formality: min(1, 0.20 + formal * 0.80),
            directness: min(1, 0.42 + direct * 0.58),
            detail: min(1, 0.32 + detail * 0.68),
            styleMarkers: markers
        )
    }

    static func blend(_ base: VoiceMetrics, _ overlay: VoiceMetrics, overlayWeight: Double) -> VoiceMetrics {
        let weight = min(max(overlayWeight, 0), 1)
        func mixed(_ lhs: Double, _ rhs: Double) -> Double { lhs * (1 - weight) + rhs * weight }
        return VoiceMetrics(
            averageSentenceLength: mixed(base.averageSentenceLength, overlay.averageSentenceLength),
            emojiRate: mixed(base.emojiRate, overlay.emojiRate),
            exclamationRate: mixed(base.exclamationRate, overlay.exclamationRate),
            formality: mixed(base.formality, overlay.formality),
            directness: mixed(base.directness, overlay.directness),
            detail: mixed(base.detail, overlay.detail),
            styleMarkers: Array((overlay.styleMarkers + base.styleMarkers).uniqued().prefix(8))
        )
    }

    static func distance(_ lhs: VoiceMetrics, _ rhs: VoiceMetrics) -> Double {
        let sentenceScale = max(max(lhs.averageSentenceLength, rhs.averageSentenceLength), 1)
        let components = [
            abs(lhs.averageSentenceLength - rhs.averageSentenceLength) / sentenceScale,
            abs(lhs.emojiRate - rhs.emojiRate),
            abs(lhs.exclamationRate - rhs.exclamationRate),
            abs(lhs.formality - rhs.formality),
            abs(lhs.directness - rhs.directness),
            abs(lhs.detail - rhs.detail)
        ]
        return min(1, components.reduce(0, +) / Double(components.count))
    }

    private static func normalizedMarkerScore(_ markers: [String], in text: String) -> Double {
        let hits = markers.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        return min(1, Double(hits) / 3)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private struct IntelligenceVaultPayload: Codable, Equatable {
    var schemaVersion = 2
    var relationships: [RelationshipProfile] = []
    var voice = VoiceProfile()
    var pendingRewrites: [PendingRewriteSample] = []
    var rewriteHistory: [RewriteHistoryEntry] = []
    var safety = SafetyPreferences()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, relationships, voice, pendingRewrites, rewriteHistory, safety
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        relationships = try container.decodeIfPresent([RelationshipProfile].self, forKey: .relationships) ?? []
        voice = try container.decodeIfPresent(VoiceProfile.self, forKey: .voice) ?? VoiceProfile()
        pendingRewrites = try container.decodeIfPresent([PendingRewriteSample].self, forKey: .pendingRewrites) ?? []
        rewriteHistory = try container.decodeIfPresent([RewriteHistoryEntry].self, forKey: .rewriteHistory) ?? []
        safety = try container.decodeIfPresent(SafetyPreferences.self, forKey: .safety) ?? SafetyPreferences()
    }
}

final class CommunicationIntelligenceStore: ObservableObject {
    @Published private(set) var relationships: [RelationshipProfile]
    @Published private(set) var voice: VoiceProfile
    @Published private(set) var safety: SafetyPreferences
    @Published private(set) var rewriteHistory: [RewriteHistoryEntry]

    private var payload: IntelligenceVaultPayload
    private let fileURL: URL
    private let keyStore: KeychainStore
    private let injectedKey: Data?
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        legacyProfiles: [ConversationProfile] = [],
        fileURL: URL? = nil,
        encryptionKey: Data? = nil
    ) {
        self.defaults = defaults
        self.keyStore = KeychainStore(account: "communication-intelligence-key-v1")
        self.injectedKey = encryptionKey
        self.fileURL = fileURL ?? Self.defaultFileURL()
        let loaded = Self.loadPayload(
            from: self.fileURL,
            keyStore: self.keyStore,
            injectedKey: encryptionKey
        )
        var initial = loaded ?? IntelligenceVaultPayload()
        initial.schemaVersion = 2
        initial.rewriteHistory = RewriteHistoryPolicy.retained(initial.rewriteHistory)
        if loaded == nil, !legacyProfiles.isEmpty {
            initial.relationships = legacyProfiles.map {
                RelationshipProfile(
                    id: $0.id,
                    applicationIdentifier: $0.applicationIdentifier,
                    conversationTitle: $0.conversationTitle,
                    role: $0.role,
                    confidence: 1,
                    evidence: ["从旧版聊天对象规则迁移"],
                    customInstruction: $0.customInstruction,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }
        }
        initial.pendingRewrites.removeAll { Date().timeIntervalSince($0.createdAt) > 86_400 }
        self.payload = initial
        self.relationships = initial.relationships.sorted { $0.updatedAt > $1.updatedAt }
        self.voice = initial.voice
        self.rewriteHistory = initial.rewriteHistory.sorted { $0.createdAt > $1.createdAt }
        self.safety = initial.safety
        if loaded == nil, !legacyProfiles.isEmpty, persist() {
            defaults.removeObject(forKey: ConversationProfileStore.storageKey)
        }
    }

    func relationship(for snapshot: ConversationSnapshot) -> RelationshipProfile? {
        relationships.first { $0.matches(snapshot) }
    }

    @discardableResult
    func createManualRelationship(
        for snapshot: ConversationSnapshot,
        role: ConversationRole,
        customInstruction: String
    ) -> RelationshipProfile? {
        guard let title = snapshot.title, snapshot.canCreateProfile else { return nil }
        let profile = RelationshipProfile(
            applicationIdentifier: snapshot.applicationIdentifier,
            conversationTitle: title,
            role: role,
            confidence: 1,
            evidence: ["用户手动确认"],
            customInstruction: customInstruction
        )
        upsert(profile)
        return profile
    }

    @discardableResult
    func createInferredRelationship(for snapshot: ConversationSnapshot) -> RelationshipProfile? {
        guard let role = ConversationRoleInference.infer(from: snapshot.title),
              let title = snapshot.title,
              snapshot.canCreateProfile else { return nil }
        let profile = RelationshipProfile(
            applicationIdentifier: snapshot.applicationIdentifier,
            conversationTitle: title,
            role: role,
            confidence: 0.86,
            evidence: ["会话称谓具有明确关系含义"]
        )
        upsert(profile)
        return profile
    }

    @discardableResult
    func applyAnalysis(
        _ analysis: RelationshipAnalysis,
        snapshot: ConversationSnapshot,
        conversationID: String?,
        messages: [ConversationMessage],
        analyzedAt: Date = Date()
    ) -> RelationshipProfile? {
        guard let title = snapshot.title else { return nil }
        let now = analyzedAt
        let existing = relationship(for: snapshot)
        if let lastAnalyzedAt = existing?.lastAnalyzedAt,
           now.timeIntervalSince(lastAnalyzedAt) < 86_400 {
            return existing
        }
        guard existing != nil || analysis.confidence >= 0.70 else { return nil }
        var profile = existing ?? RelationshipProfile(
            applicationIdentifier: snapshot.applicationIdentifier,
            conversationID: conversationID,
            conversationTitle: title,
            role: analysis.role,
            probabilities: analysis.probabilities,
            confidence: analysis.confidence,
            evidence: analysis.evidence,
            dimensions: analysis.dimensions,
            lastAnalyzedAt: now
        )
        profile.conversationID = conversationID ?? profile.conversationID
        profile.lastAnalyzedAt = now
        profile.updatedAt = now

        if analysis.role == profile.role {
            profile.probabilities = analysis.probabilities
            profile.confidence = analysis.confidence
            profile.evidence = analysis.evidence
            profile.dimensions = analysis.dimensions
            profile.pendingChange = nil
        } else if analysis.confidence > 0.75,
                  analysis.probabilities[analysis.role] - analysis.probabilities[profile.role] > 0.25 {
            if var pending = profile.pendingChange, pending.proposedRole == analysis.role {
                pending.observationCount += 1
                pending.probability = analysis.confidence
                pending.evidence = analysis.evidence
                profile.pendingChange = pending
            } else {
                profile.pendingChange = PendingRelationshipChange(
                    proposedRole: analysis.role,
                    probability: analysis.confidence,
                    observationCount: 1,
                    evidence: analysis.evidence,
                    firstObservedAt: now
                )
            }
        }
        upsert(profile)
        learnVoice(from: messages, relationshipID: profile.id)
        learnFromPendingRewrites(messages: messages, relationshipID: profile.id, conversationID: conversationID)
        return relationship(for: snapshot)
    }

    func confirmPendingChange(id: UUID) {
        guard let index = relationships.firstIndex(where: { $0.id == id }),
              let pending = relationships[index].pendingChange,
              pending.observationCount >= 2 else { return }
        relationships[index].role = pending.proposedRole
        relationships[index].probabilities[pending.proposedRole] = pending.probability
        relationships[index].confidence = pending.probability
        relationships[index].evidence = pending.evidence
        relationships[index].dimensions = .defaults(for: pending.proposedRole)
        relationships[index].customInstruction = pending.proposedRole.defaultInstruction
        relationships[index].pendingChange = nil
        relationships[index].updatedAt = Date()
        syncAndPersist()
    }

    func update(id: UUID, role: ConversationRole, customInstruction: String) {
        guard let index = relationships.firstIndex(where: { $0.id == id }) else { return }
        relationships[index].role = role
        relationships[index].probabilities = RoleProbabilities()
        relationships[index].probabilities[role] = 1
        relationships[index].confidence = 1
        relationships[index].evidence = ["用户手动确认"]
        relationships[index].dimensions = .defaults(for: role)
        relationships[index].customInstruction = role.resolvedInstruction(from: customInstruction)
        relationships[index].pendingChange = nil
        relationships[index].updatedAt = Date()
        syncAndPersist()
    }

    func delete(id: UUID) {
        relationships.removeAll { $0.id == id }
        voice.relationshipOverlays.removeAll { $0.relationshipID == id }
        payload.pendingRewrites.removeAll { $0.relationshipID == id }
        syncAndPersist()
    }

    func resetVoice() {
        voice = VoiceProfile()
        syncAndPersist()
    }

    func clearAll() {
        relationships = []
        voice = VoiceProfile()
        rewriteHistory = []
        safety = SafetyPreferences()
        payload = IntelligenceVaultPayload()
        try? FileManager.default.removeItem(at: fileURL)
        if injectedKey == nil { try? keyStore.delete() }
    }

    @discardableResult
    func recordRewrite(
        sourceText: String,
        rewrittenText: String,
        applicationRole: ApplicationWritingRole,
        relationshipID: UUID?,
        conversationID: String?
    ) -> UUID {
        let entry = RewriteHistoryEntry(
            sourceText: sourceText,
            rewrittenText: rewrittenText,
            applicationRole: applicationRole,
            relationshipID: relationshipID
        )
        rewriteHistory.insert(entry, at: 0)
        rewriteHistory = Array(
            RewriteHistoryPolicy.retained(rewriteHistory).sorted { $0.createdAt > $1.createdAt }
        )
        if applicationRole == .messaging {
            // Keep document, email and developer prose from diluting the voice
            // profile used for instant messaging.
            learnVoiceFromRewrite(entry)
        }
        recordPendingRewrite(
            text: rewrittenText,
            relationshipID: relationshipID,
            conversationID: conversationID,
            persistImmediately: false
        )
        syncAndPersist()
        return entry.id
    }

    func deleteRewriteHistory(id: UUID) {
        rewriteHistory.removeAll { $0.id == id }
        syncAndPersist()
    }

    func clearRewriteHistory() {
        rewriteHistory = []
        syncAndPersist()
    }

    func recordPendingRewrite(
        text: String,
        relationshipID: UUID?,
        conversationID: String?,
        persistImmediately: Bool = true
    ) {
        payload.pendingRewrites.removeAll { Date().timeIntervalSince($0.createdAt) > 86_400 }
        payload.pendingRewrites.append(
            PendingRewriteSample(
                relationshipID: relationshipID,
                conversationID: conversationID,
                rewrittenText: text
            )
        )
        payload.pendingRewrites = Array(payload.pendingRewrites.suffix(20))
        if persistImmediately { _ = persist() }
    }

    func applyFeedback(
        _ feedback: RewriteFeedback,
        relationshipID: UUID?,
        historyEntryID: UUID? = nil
    ) {
        if let historyEntryID,
           let index = rewriteHistory.firstIndex(where: { $0.id == historyEntryID }) {
            rewriteHistory[index].feedback = feedback
            if feedback == .good {
                let acceptedVoice = VoiceAnalyzer.metrics(from: [rewriteHistory[index].rewrittenText])
                voice.metrics = VoiceAnalyzer.blend(voice.metrics, acceptedVoice, overlayWeight: 0.20)
            } else if feedback == .notMyVoice {
                let sourceVoice = VoiceAnalyzer.metrics(from: [rewriteHistory[index].sourceText])
                voice.metrics = VoiceAnalyzer.blend(voice.metrics, sourceVoice, overlayWeight: 0.32)
            }
        }
        switch feedback {
        case .good:
            voice.metrics.directness = min(1, voice.metrics.directness + 0.01)
        case .tooFormal:
            voice.metrics.formality = max(0, voice.metrics.formality - 0.08)
        case .tooVerbose:
            voice.metrics.detail = max(0, voice.metrics.detail - 0.08)
            voice.metrics.averageSentenceLength = max(6, voice.metrics.averageSentenceLength * 0.92)
        case .notMyVoice:
            if let relationshipID,
               let overlay = voice.relationshipOverlays.first(where: { $0.relationshipID == relationshipID }) {
                voice.metrics = VoiceAnalyzer.blend(voice.metrics, overlay.metrics, overlayWeight: 0.25)
            }
        case .factIncorrect:
            safety.factIssueCount += 1
            safety.preferredExpansionRatio = max(1.12, safety.preferredExpansionRatio - 0.05)
        }
        voice.updatedAt = Date()
        syncAndPersist()
    }

    func exportDerivedProfileData() throws -> Data {
        struct Export: Encodable {
            let schemaVersion: Int
            let relationships: [RelationshipProfile]
            let voice: VoiceProfile
            let safety: SafetyPreferences
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            Export(schemaVersion: payload.schemaVersion, relationships: relationships, voice: voice, safety: safety)
        )
    }

    private func learnVoice(from messages: [ConversationMessage], relationshipID: UUID) {
        let sent = messages
            .filter { $0.direction == .sent }
            .compactMap(\.usableText)
        guard sent.count >= 3 else { return }
        let learned = VoiceAnalyzer.metrics(from: sent)
        let oldGlobalWeight = voice.sampleCount == 0 ? 0.0 : min(0.85, Double(voice.sampleCount) / Double(voice.sampleCount + sent.count))
        voice.metrics = VoiceAnalyzer.blend(learned, voice.metrics, overlayWeight: oldGlobalWeight)
        voice.sampleCount += sent.count
        if let index = voice.relationshipOverlays.firstIndex(where: { $0.relationshipID == relationshipID }) {
            let old = voice.relationshipOverlays[index]
            let oldWeight = min(0.80, Double(old.sampleCount) / Double(old.sampleCount + sent.count))
            voice.relationshipOverlays[index] = VoiceOverlay(
                relationshipID: relationshipID,
                sampleCount: old.sampleCount + sent.count,
                metrics: VoiceAnalyzer.blend(learned, old.metrics, overlayWeight: oldWeight),
                updatedAt: Date()
            )
        } else {
            voice.relationshipOverlays.append(
                VoiceOverlay(relationshipID: relationshipID, sampleCount: sent.count, metrics: learned, updatedAt: Date())
            )
        }
        voice.updatedAt = Date()
        syncAndPersist()
    }

    private func learnVoiceFromRewrite(_ entry: RewriteHistoryEntry) {
        let learned = RewriteHistoryPolicy.learnedMetrics(
            sourceText: entry.sourceText,
            rewrittenText: entry.rewrittenText
        )
        let previousCount = voice.sampleCount
        let previousWeight = previousCount == 0
            ? 0.0
            : min(0.92, Double(previousCount) / Double(previousCount + 1))
        voice.metrics = VoiceAnalyzer.blend(learned, voice.metrics, overlayWeight: previousWeight)
        voice.sampleCount += 1
        if let relationshipID = entry.relationshipID {
            if let index = voice.relationshipOverlays.firstIndex(where: { $0.relationshipID == relationshipID }) {
                let old = voice.relationshipOverlays[index]
                let oldWeight = min(0.88, Double(old.sampleCount) / Double(old.sampleCount + 1))
                voice.relationshipOverlays[index] = VoiceOverlay(
                    relationshipID: relationshipID,
                    sampleCount: old.sampleCount + 1,
                    metrics: VoiceAnalyzer.blend(learned, old.metrics, overlayWeight: oldWeight),
                    updatedAt: Date()
                )
            } else {
                voice.relationshipOverlays.append(
                    VoiceOverlay(
                        relationshipID: relationshipID,
                        sampleCount: 1,
                        metrics: learned,
                        updatedAt: Date()
                    )
                )
            }
        }
        voice.updatedAt = Date()
    }

    private func learnFromPendingRewrites(
        messages: [ConversationMessage],
        relationshipID: UUID,
        conversationID: String?
    ) {
        let now = Date()
        let sent = messages.filter { $0.direction == .sent }.compactMap { message -> (Date, String)? in
            message.usableText.map { (message.timestamp, $0) }
        }
        var matchedFinals: [(PendingRewriteSample, String)] = []
        payload.pendingRewrites.removeAll { sample in
            guard now.timeIntervalSince(sample.createdAt) <= 86_400 else { return true }
            guard sample.relationshipID == relationshipID,
                  sample.conversationID == conversationID else { return false }
            if let match = sent.first(where: {
                $0.0 >= sample.createdAt.addingTimeInterval(-30)
                    && $0.0 <= sample.createdAt.addingTimeInterval(300)
                    && TextFingerprint.similarity(sample.fingerprint, TextFingerprint.make($0.1)) >= 0.55
            }) {
                matchedFinals.append((sample, match.1))
                return true
            }
            return false
        }
        if !matchedFinals.isEmpty {
            for (sample, finalText) in matchedFinals {
                let finalVoice = VoiceAnalyzer.metrics(from: [finalText])
                let distance = VoiceAnalyzer.distance(sample.generatedVoice, finalVoice)
                let correctionWeight = min(0.65, 0.25 + distance * 0.50)
                voice.metrics = VoiceAnalyzer.blend(
                    voice.metrics,
                    finalVoice,
                    overlayWeight: correctionWeight
                )
                if let overlayIndex = voice.relationshipOverlays.firstIndex(where: {
                    $0.relationshipID == relationshipID
                }) {
                    voice.relationshipOverlays[overlayIndex].metrics = VoiceAnalyzer.blend(
                        voice.relationshipOverlays[overlayIndex].metrics,
                        finalVoice,
                        overlayWeight: correctionWeight
                    )
                    voice.relationshipOverlays[overlayIndex].updatedAt = now
                }
            }
            voice.updatedAt = now
        }
        syncAndPersist()
    }

    private func upsert(_ profile: RelationshipProfile) {
        if let index = relationships.firstIndex(where: {
            $0.applicationIdentifier == profile.applicationIdentifier
                && $0.normalizedTitle == profile.normalizedTitle
        }) {
            relationships[index] = profile
        } else {
            relationships.append(profile)
        }
        relationships.sort { $0.updatedAt > $1.updatedAt }
        syncAndPersist()
    }

    private func syncAndPersist() {
        payload.relationships = relationships
        payload.voice = voice
        payload.rewriteHistory = rewriteHistory
        payload.safety = safety
        _ = persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let cleartext = try encoder.encode(payload)
            let key = try encryptionKey()
            guard let combined = try AES.GCM.seal(cleartext, using: key).combined else { return false }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try combined.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let injectedKey { return SymmetricKey(data: injectedKey) }
        if let saved = try keyStore.readData(), saved.count == 32 {
            return SymmetricKey(data: saved)
        }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        try keyStore.saveData(data)
        return SymmetricKey(data: data)
    }

    private static func loadPayload(
        from fileURL: URL,
        keyStore: KeychainStore,
        injectedKey: Data?
    ) -> IntelligenceVaultPayload? {
        guard let encrypted = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let keyData: Data
            if let injectedKey {
                keyData = injectedKey
            } else if let saved = try keyStore.readData(), saved.count == 32 {
                keyData = saved
            } else {
                return nil
            }
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let cleartext = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            var payload = try decoder.decode(IntelligenceVaultPayload.self, from: cleartext)
            guard (1...2).contains(payload.schemaVersion) else { return nil }
            payload.schemaVersion = 2
            return payload
        } catch {
            return nil
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Pole/intelligence-v1.dat")
    }
}

enum TextSimilarity {
    static func ratio(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(longest)
    }
}

enum TextFingerprint {
    static func make(_ text: String) -> UInt64 {
        let characters = Array(
            text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        )
        guard !characters.isEmpty else { return 0 }
        let shingles: [String]
        if characters.count == 1 {
            shingles = [String(characters[0])]
        } else {
            shingles = (0..<(characters.count - 1)).map {
                String(characters[$0...($0 + 1)])
            }
        }
        var weights = Array(repeating: 0, count: 64)
        for shingle in shingles {
            let hash = fnv1a(shingle)
            for bit in 0..<64 {
                weights[bit] += (hash & (UInt64(1) << UInt64(bit))) == 0 ? -1 : 1
            }
        }
        return weights.enumerated().reduce(UInt64(0)) { result, item in
            item.element >= 0 ? result | (UInt64(1) << UInt64(item.offset)) : result
        }
    }

    static func similarity(_ lhs: UInt64, _ rhs: UInt64) -> Double {
        guard lhs != 0 || rhs != 0 else { return 1 }
        return 1 - Double((lhs ^ rhs).nonzeroBitCount) / 64.0
    }

    private static func fnv1a(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

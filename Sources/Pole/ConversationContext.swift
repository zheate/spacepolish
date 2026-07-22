import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import Vision

enum ConversationTitleSource: String, Codable, Equatable {
    case none
    case ocr
    case accessibilityHeader
    case windowTitle

    fileprivate var priority: Int {
        switch self {
        case .windowTitle:
            return 3
        case .accessibilityHeader:
            return 2
        case .ocr:
            return 1
        case .none:
            return 0
        }
    }
}

struct ConversationTitleCandidate: Equatable {
    let title: String
    let source: ConversationTitleSource
    let confidence: Double
}

enum ConversationTitleNormalizer {
    private static let genericTitles: Set<String> = [
        "微信", "企业微信", "wecom", "wechat", "消息", "聊天", "搜索", "设置", "关闭",
        "新建聊天", "new chat", "messages", "chat", "search", "settings", "close"
    ]

    private static let interfaceMetadataTitles: Set<String> = [
        "刚刚", "今天", "昨天", "前天",
        "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日", "星期天",
        "周一", "周二", "周三", "周四", "周五", "周六", "周日", "周天",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
    ]

    private static let interfaceMetadataPatterns = [
        #"^(?:[01]?\d|2[0-3]):[0-5]\d$"#,
        #"^(?:上午|下午|早上|晚上)\s*(?:[01]?\d|2[0-3]):[0-5]\d$"#,
        #"^\d{1,2}月\d{1,2}日(?:\s+(?:[01]?\d|2[0-3]):[0-5]\d)?$"#,
        #"^\d{4}[./-]\d{1,2}[./-]\d{1,2}$"#,
        #"^\d{1,2}[./-]\d{1,2}$"#
    ]

    static func normalize(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 96 else { return nil }

        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
    }

    static func isUsable(_ title: String, applicationName: String?) -> Bool {
        guard let normalized = normalize(title) else { return false }
        let lowercaseTitle = normalized.lowercased()
        if genericTitles.contains(lowercaseTitle)
            || interfaceMetadataTitles.contains(lowercaseTitle)
            || interfaceMetadataPatterns.contains(where: {
                lowercaseTitle.range(of: $0, options: .regularExpression) != nil
            }) {
            return false
        }
        if let applicationName,
           let normalizedApplicationName = normalize(applicationName),
           normalized == normalizedApplicationName {
            return false
        }
        return normalized.rangeOfCharacter(from: .alphanumerics) != nil
    }
}

enum ConversationCandidateSelector {
    static let automaticBindThreshold = 0.85

    static func bestCandidate(
        _ candidates: [ConversationTitleCandidate],
        applicationName: String?
    ) -> ConversationTitleCandidate? {
        candidates
            .filter { ConversationTitleNormalizer.isUsable($0.title, applicationName: applicationName) }
            .max { lhs, rhs in
                if lhs.source.priority != rhs.source.priority {
                    return lhs.source.priority < rhs.source.priority
                }
                return lhs.confidence < rhs.confidence
            }
    }

    static func preferredCandidate(
        accessibilityCandidate: ConversationTitleCandidate?,
        ocrCandidate: ConversationTitleCandidate?
    ) -> ConversationTitleCandidate? {
        if let accessibilityCandidate,
           accessibilityCandidate.confidence >= automaticBindThreshold {
            return accessibilityCandidate
        }
        if let ocrCandidate,
           ocrCandidate.confidence >= automaticBindThreshold {
            return ocrCandidate
        }
        return accessibilityCandidate ?? ocrCandidate
    }
}

struct ConversationSnapshot: Equatable {
    let applicationIdentifier: String
    let applicationContext: ApplicationContext
    let processIdentifier: pid_t
    let windowIdentifier: CGWindowID?
    let title: String?
    let normalizedTitle: String?
    let source: ConversationTitleSource
    let confidence: Double

    init(
        applicationIdentifier: String,
        processIdentifier: pid_t,
        windowIdentifier: CGWindowID?,
        candidate: ConversationTitleCandidate?,
        applicationContext: ApplicationContext? = nil
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.applicationContext = applicationContext ?? ApplicationContextClassifier.context(
            bundleIdentifier: applicationIdentifier
        )
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.title = candidate?.title
        self.normalizedTitle = candidate.flatMap { ConversationTitleNormalizer.normalize($0.title) }
        self.source = candidate?.source ?? .none
        self.confidence = candidate?.confidence ?? 0
    }

    var canCreateProfile: Bool {
        applicationContext.supportsConversationProfiles
            && normalizedTitle != nil
            && confidence >= ConversationCandidateSelector.automaticBindThreshold
    }

    func matches(_ current: ConversationSnapshot) -> Bool {
        guard applicationIdentifier == current.applicationIdentifier,
              processIdentifier == current.processIdentifier,
              windowIdentifier == current.windowIdentifier else {
            return false
        }
        return normalizedTitle == current.normalizedTitle
    }

    func matchesForWriteback(_ current: ConversationSnapshot) -> Bool {
        guard applicationIdentifier == current.applicationIdentifier,
              processIdentifier == current.processIdentifier,
              windowIdentifier == current.windowIdentifier else {
            return false
        }

        if let currentTitle = current.normalizedTitle {
            return normalizedTitle == currentTitle
        }

        // OCR-backed titles cannot be re-read cheaply. The captured text element
        // is still checked separately before writeback, so the same app/window is
        // sufficient when the lightweight pass has no accessible title.
        return source == .ocr || source == .none
    }
}

enum ConversationRole: String, CaseIterable, Codable, Equatable {
    case manager
    case customer
    case colleague
    case friendOrFamily
    case custom

    var displayName: String {
        switch self {
        case .manager:
            return "上级"
        case .customer:
            return "客户"
        case .colleague:
            return "同事"
        case .friendOrFamily:
            return "朋友 / 家人"
        case .custom:
            return "自定义"
        }
    }

    var defaultInstruction: String {
        switch self {
        case .manager:
            return "保持尊重，但用自然的聊天口吻，像平时直接沟通；说清原文已有的结论、进度或问题，不要改成工作汇报或层层铺垫，也不增加承诺、解释或结论。"
        case .customer:
            return "礼貌、清楚，但保持正常聊天的口语感；礼貌不等于正式，不要改成客服、邮件或公文语气，也不添加称呼、客套话、交付承诺、时间或责任。"
        case .colleague:
            return "自然、直接、好沟通，保留同事间正常说话的节奏；不要改成工作汇报、会议纪要或任务指令，也不添加原文没有的下一步或配合要求。"
        case .friendOrFamily:
            return "保持本人日常聊天的口吻和亲疏程度，自然、亲切即可；原文已经自然时只做最小修改。保留每个动作、对象、目的和先后关系，不要为了缩短而删成命令清单；保留有助于请求语气和聊天节奏的适度重复，原文没有句号时不要强行补句号。不要刻意热情、卖萌、解释或添加客套话。"
        case .custom:
            return "保持原文的说话方式和语气，只做必要的清晰度与流畅度调整。"
        }
    }

    private var legacyDefaultInstructions: [String] {
        switch self {
        case .manager:
            return ["语气尊重、简洁，优先交代结论、进度或明确问题；保留原文的确定程度，不增加承诺或解释。"]
        case .customer:
            return ["语气礼貌、清晰、专业；说明要便于对方执行，不增加原文没有的交付承诺、时间或责任。"]
        case .colleague:
            return ["表达直接、协作、信息完整；优先说清下一步和需要配合的事项，避免过度正式。"]
        case .friendOrFamily:
            return [
                "保持自然、亲切的日常口语，不要写成工作汇报或模板化客套话。",
                "保持本人日常聊天的口吻和亲疏程度，自然、亲切即可；不要刻意热情、卖萌、解释或添加客套话。"
            ]
        case .custom:
            return ["保持自然、清晰，并忠实保留原意和语气。"]
        }
    }

    func resolvedInstruction(from instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || legacyDefaultInstructions.contains(trimmed) {
            return defaultInstruction
        }
        return trimmed
    }
}

enum ConversationRoleInference {
    private static let friendOrFamilyTitles: Set<String> = [
        "老婆", "老婆大人", "老公", "老公大人", "媳妇", "媳妇儿", "爱人", "对象", "伴侣",
        "亲爱的", "宝贝", "宝宝", "wife", "husband",
        "妈妈", "老妈", "母亲", "爸爸", "老爸", "父亲", "岳母", "岳父", "婆婆", "公公",
        "儿子", "女儿", "闺女", "哥哥", "姐姐", "弟弟", "妹妹", "家人", "家人群", "家庭群",
        "闺蜜", "兄弟", "发小", "bestie"
    ]

    private static let managerTitles: Set<String> = [
        "老板", "领导", "直属领导", "主管", "上司", "boss"
    ]

    private static let customerTitles: Set<String> = [
        "客户", "客户群", "甲方", "甲方群"
    ]

    private static let colleagueTitles: Set<String> = [
        "同事", "同事群", "搭档", "合伙人"
    ]

    static func infer(from title: String?) -> ConversationRole? {
        guard let title,
              let normalized = ConversationTitleNormalizer.normalize(title) else {
            return nil
        }

        var inferredRoles: [ConversationRole] = []
        for token in semanticTokens(in: normalized) {
            if friendOrFamilyTitles.contains(token) {
                inferredRoles.appendIfMissing(.friendOrFamily)
            }
            if managerTitles.contains(token) {
                inferredRoles.appendIfMissing(.manager)
            }
            if customerTitles.contains(token) {
                inferredRoles.appendIfMissing(.customer)
            }
            if colleagueTitles.contains(token) {
                inferredRoles.appendIfMissing(.colleague)
            }
        }
        return inferredRoles.count == 1 ? inferredRoles[0] : nil
    }

    private static func semanticTokens(in title: String) -> [String] {
        let lowered = title.lowercased()
        var tokens: [String] = []
        var current = ""

        func finishCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
        }

        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                finishCurrentToken()
            }
        }
        finishCurrentToken()
        return tokens
    }
}

private extension Array where Element == ConversationRole {
    mutating func appendIfMissing(_ role: ConversationRole) {
        guard !contains(role) else { return }
        append(role)
    }
}

struct ConversationProfile: Codable, Equatable, Identifiable {
    let id: UUID
    let applicationIdentifier: String
    let conversationTitle: String
    var role: ConversationRole
    var customInstruction: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        applicationIdentifier: String,
        conversationTitle: String,
        role: ConversationRole,
        customInstruction: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.applicationIdentifier = applicationIdentifier
        self.conversationTitle = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
        self.customInstruction = role.resolvedInstruction(
            from: customInstruction ?? role.defaultInstruction
        )
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var normalizedTitle: String? {
        ConversationTitleNormalizer.normalize(conversationTitle)
    }

    func matches(_ snapshot: ConversationSnapshot) -> Bool {
        snapshot.applicationContext.supportsConversationProfiles
            && applicationIdentifier == snapshot.applicationIdentifier
            && normalizedTitle != nil
            && normalizedTitle == snapshot.normalizedTitle
    }

    var modelInstruction: String {
        let instruction = role.resolvedInstruction(from: customInstruction)
        let trimmedTitle = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return instruction }
        let compactTitle = trimmedTitle.replacingOccurrences(of: " ", with: "")
        return [trimmedTitle, compactTitle]
            .filter { !$0.isEmpty }
            .reduce(instruction) { partialInstruction, title in
                partialInstruction.replacingOccurrences(
                    of: title,
                    with: "对方",
                    options: [.caseInsensitive]
                )
            }
    }
}

final class ConversationProfileStore: ObservableObject {
    static let storageKey = "conversationProfiles.v1"

    @Published private(set) var profiles: [ConversationProfile]

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? decoder.decode([ConversationProfile].self, from: data) {
            let migrated = decoded.map { profile -> ConversationProfile in
                var profile = profile
                profile.customInstruction = profile.role.resolvedInstruction(
                    from: profile.customInstruction
                )
                return profile
            }
            self.profiles = migrated
                .filter { $0.normalizedTitle != nil }
                .sorted { $0.updatedAt > $1.updatedAt }
            if migrated != decoded {
                persist()
            }
        } else {
            self.profiles = []
        }
    }

    func profile(for snapshot: ConversationSnapshot) -> ConversationProfile? {
        guard snapshot.applicationContext.supportsConversationProfiles else { return nil }
        return profiles.first { $0.matches(snapshot) }
    }

    @discardableResult
    func createProfile(
        for snapshot: ConversationSnapshot,
        role: ConversationRole,
        customInstruction: String
    ) -> ConversationProfile? {
        guard let title = snapshot.title,
              snapshot.canCreateProfile else {
            return nil
        }
        let profile = ConversationProfile(
            applicationIdentifier: snapshot.applicationIdentifier,
            conversationTitle: title,
            role: role,
            customInstruction: customInstruction
        )
        upsert(profile)
        return profile
    }

    @discardableResult
    func createInferredProfile(for snapshot: ConversationSnapshot) -> ConversationProfile? {
        guard let inferredRole = ConversationRoleInference.infer(from: snapshot.title) else {
            return nil
        }
        return createProfile(
            for: snapshot,
            role: inferredRole,
            customInstruction: inferredRole.defaultInstruction
        )
    }

    func update(
        id: UUID,
        role: ConversationRole,
        customInstruction: String
    ) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].role = role
        profiles[index].customInstruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].updatedAt = Date()
        sortAndPersist()
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    private func upsert(_ profile: ConversationProfile) {
        if let index = profiles.firstIndex(where: {
            $0.applicationIdentifier == profile.applicationIdentifier
                && $0.normalizedTitle == profile.normalizedTitle
        }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        sortAndPersist()
    }

    private func sortAndPersist() {
        profiles.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(profiles) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum ScreenCapturePermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func request() {
        guard !isGranted else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum ConversationContextError: LocalizedError {
    case changed

    var errorDescription: String? {
        switch self {
        case .changed:
            return "当前聊天对象已切换，未写入优化结果"
        }
    }
}

enum ConversationResolutionMode: Equatable {
    case full
    case writebackValidation

    var usesOCR: Bool {
        self == .full
    }
}

final class ConversationResolver {
    private static let textRecognitionQueue = DispatchQueue(
        label: "com.spacepolish.conversation-ocr",
        qos: .userInitiated
    )

    private struct WindowContext {
        let element: AXUIElement?
        let frame: CGRect?
        let identifier: CGWindowID?
    }

    static func prewarmTextRecognition() {
        textRecognitionQueue.async {
            guard let image = blankPrewarmImage() else { return }
            _ = performTextRecognition(on: image)
        }
    }

    func resolveCurrentConversation(
        mode: ConversationResolutionMode = .full
    ) -> ConversationSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let applicationIdentifier = application.bundleIdentifier else {
            return nil
        }

        let processIdentifier = application.processIdentifier
        let applicationContext = ApplicationContextClassifier.context(
            bundleIdentifier: applicationIdentifier,
            localizedName: application.localizedName
        )
        let accessibilityApplication = AXUIElementCreateApplication(processIdentifier)
        let window = windowContext(
            for: accessibilityApplication,
            processIdentifier: processIdentifier
        )
        guard applicationContext.supportsConversationProfiles else {
            return ConversationSnapshot(
                applicationIdentifier: applicationIdentifier,
                processIdentifier: processIdentifier,
                windowIdentifier: window.identifier,
                candidate: nil,
                applicationContext: applicationContext
            )
        }
        let accessibilityCandidates = accessibilityCandidates(
            in: window.element,
            frame: window.frame,
            applicationName: application.localizedName
        )
        let accessibilityCandidate = ConversationCandidateSelector.bestCandidate(
            accessibilityCandidates,
            applicationName: application.localizedName
        )
        if let accessibilityCandidate,
           accessibilityCandidate.confidence >= ConversationCandidateSelector.automaticBindThreshold {
            return ConversationSnapshot(
                applicationIdentifier: applicationIdentifier,
                processIdentifier: processIdentifier,
                windowIdentifier: window.identifier,
                candidate: accessibilityCandidate,
                applicationContext: applicationContext
            )
        }

        guard mode.usesOCR else {
            return ConversationSnapshot(
                applicationIdentifier: applicationIdentifier,
                processIdentifier: processIdentifier,
                windowIdentifier: window.identifier,
                candidate: nil,
                applicationContext: applicationContext
            )
        }

        let ocrCandidate = window.identifier.flatMap {
            ocrCandidate(
                windowIdentifier: $0,
                applicationName: application.localizedName
            )
        }
        let candidate = ConversationCandidateSelector.preferredCandidate(
            accessibilityCandidate: accessibilityCandidate,
            ocrCandidate: ocrCandidate
        )

        return ConversationSnapshot(
            applicationIdentifier: applicationIdentifier,
            processIdentifier: processIdentifier,
            windowIdentifier: window.identifier,
            candidate: candidate,
            applicationContext: applicationContext
        )
    }

    func matchesCurrentConversation(_ snapshot: ConversationSnapshot) -> Bool {
        guard let current = resolveCurrentConversation(mode: .writebackValidation) else {
            return false
        }
        return snapshot.matchesForWriteback(current)
    }

    func isTargetOrPoleFrontmost(_ snapshot: ConversationSnapshot) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.processIdentifier == snapshot.processIdentifier
            || frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    func reactivate(_ snapshot: ConversationSnapshot) {
        NSRunningApplication(processIdentifier: snapshot.processIdentifier)?
            .activate(options: [])
    }

    private func windowContext(
        for application: AXUIElement,
        processIdentifier: pid_t
    ) -> WindowContext {
        let window = elementAttribute(kAXFocusedWindowAttribute as CFString, from: application)
            ?? childElements(of: application, attribute: kAXWindowsAttribute as CFString).first
        let frame = window.flatMap(frame(of:))
        return WindowContext(
            element: window,
            frame: frame,
            identifier: matchingWindowIdentifier(
                processIdentifier: processIdentifier,
                accessibilityFrame: frame
            )
        )
    }

    private func accessibilityCandidates(
        in window: AXUIElement?,
        frame windowFrame: CGRect?,
        applicationName: String?
    ) -> [ConversationTitleCandidate] {
        guard let window else { return [] }

        var candidates: [ConversationTitleCandidate] = []
        if let title = stringAttribute(kAXTitleAttribute as CFString, from: window),
           ConversationTitleNormalizer.isUsable(title, applicationName: applicationName) {
            candidates.append(
                ConversationTitleCandidate(
                    title: title,
                    source: .windowTitle,
                    confidence: 0.96
                )
            )
        }

        guard let windowFrame else { return candidates }
        let headerHeight = min(max(windowFrame.height * 0.28, 76), 220)
        let headerBottom = windowFrame.minY + headerHeight
        var examinedElements = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 5, examinedElements < 160 else { return }
            examinedElements += 1

            let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
            if role == (kAXStaticTextRole as String),
               let elementFrame = frame(of: element),
               elementFrame.midY >= windowFrame.minY,
               elementFrame.midY <= headerBottom,
               let title = stringAttribute(kAXTitleAttribute as CFString, from: element)
                    ?? stringAttribute(kAXValueAttribute as CFString, from: element),
               ConversationTitleNormalizer.isUsable(title, applicationName: applicationName) {
                let horizontalDistance = abs(elementFrame.midX - windowFrame.midX)
                    / max(windowFrame.width, 1)
                let centeredness = max(0, 1 - horizontalDistance * 2)
                let verticalRatio = (elementFrame.midY - windowFrame.minY) / max(headerHeight, 1)
                let topness = max(0, 1 - verticalRatio)
                let confidence = min(0.95, 0.72 + centeredness * 0.18 + topness * 0.08)
                candidates.append(
                    ConversationTitleCandidate(
                        title: title,
                        source: .accessibilityHeader,
                        confidence: confidence
                    )
                )
            }

            for child in childElements(of: element, attribute: kAXChildrenAttribute as CFString) {
                visit(child, depth: depth + 1)
            }
        }

        visit(window, depth: 0)
        return candidates
    }

    private func ocrCandidate(
        windowIdentifier: CGWindowID,
        applicationName: String?
    ) -> ConversationTitleCandidate? {
        guard ScreenCapturePermission.isGranted,
              let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowIdentifier,
                [.boundsIgnoreFraming, .bestResolution]
              ) else {
            return nil
        }

        let headerHeight = max(1, min(image.height * 28 / 100, 320))
        let cropRect = CGRect(x: 0, y: 0, width: image.width, height: headerHeight)
        guard let headerImage = image.cropping(to: cropRect) else { return nil }

        let observations = Self.textRecognitionQueue.sync {
            Self.performTextRecognition(on: headerImage)
        }
        let candidates = observations.compactMap { observation -> ConversationTitleCandidate? in
            guard let recognizedText = observation.topCandidates(1).first,
                  ConversationTitleNormalizer.isUsable(recognizedText.string, applicationName: applicationName) else {
                return nil
            }
            let centeredness = max(0, 1 - abs(observation.boundingBox.midX - 0.5) * 2)
            let topness = max(0, observation.boundingBox.maxY)
            let confidence = min(
                0.99,
                Double(recognizedText.confidence) * 0.72 + centeredness * 0.20 + topness * 0.08
            )
            return ConversationTitleCandidate(
                title: recognizedText.string,
                source: .ocr,
                confidence: confidence
            )
        }
        return ConversationCandidateSelector.bestCandidate(candidates, applicationName: applicationName)
    }

    private static func performTextRecognition(
        on image: CGImage
    ) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return request.results ?? []
        } catch {
            return []
        }
    }

    private static func blankPrewarmImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()
    }

    private func matchingWindowIdentifier(
        processIdentifier: pid_t,
        accessibilityFrame: CGRect?
    ) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let matchingWindows = windowInfos.compactMap { info -> (identifier: CGWindowID, frame: CGRect)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  let identifier = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
                return nil
            }
            var frame = CGRect.zero
            guard let rawBounds = info[kCGWindowBounds as String] else {
                return nil
            }
            let bounds = rawBounds as! CFDictionary
            guard CGRectMakeWithDictionaryRepresentation(bounds, &frame),
                  !frame.isEmpty else {
                return nil
            }
            return (identifier, frame)
        }

        guard let accessibilityFrame else {
            return matchingWindows.first?.identifier
        }
        return matchingWindows.max { lhs, rhs in
            overlapArea(lhs.frame, accessibilityFrame) < overlapArea(rhs.frame, accessibilityFrame)
        }?.identifier
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        let elementValue: AXUIElement = value as! AXUIElement
        return elementValue
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func childElements(of element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let children = value as? [AXUIElement] else {
            return []
        }
        return children
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func pointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        guard let value = axValue(attribute, from: element), AXValueGetType(value) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        guard let value = axValue(attribute, from: element), AXValueGetType(value) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func axValue(_ attribute: CFString, from element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue: AXValue = value as! AXValue
        return axValue
    }
}

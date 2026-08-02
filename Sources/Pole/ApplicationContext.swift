import Foundation

enum ApplicationWritingRole: String, Codable, Equatable {
    case aiDevelopmentAssistant
    case aiAssistant
    case messaging
    case email
    case development
    case document
    case generic

    var displayName: String {
        switch self {
        case .aiDevelopmentAssistant:
            return "AI 开发助手"
        case .aiAssistant:
            return "AI 助手"
        case .messaging:
            return "聊天对象"
        case .email:
            return "邮件沟通"
        case .development:
            return "开发编辑"
        case .document:
            return "文档写作"
        case .generic:
            return "通用"
        }
    }

    var supportsConversationProfiles: Bool {
        self == .messaging
    }

    var modelInstruction: String? {
        switch self {
        case .aiDevelopmentAssistant:
            return """
            当前内容用于和 AI 开发助手协作。优先明确目标、现状、期望结果和必要约束；完整保留代码、命令、路径、文件名、参数和专业术语。不要套用上级、客户、同事或朋友等人际关系语气，也不要增加原文没有的技术结论、需求或操作授权。
            """
        case .aiAssistant:
            return """
            当前内容用于向 AI 助手提问或下达任务。清楚表达目标、背景、输出要求和限制条件；保留关键名词与上下文。不要套用面向上级、客户或朋友的人际关系语气，也不要擅自增加需求。
            """
        case .email:
            return """
            当前内容用于邮件沟通。表达应清晰、完整、便于对方执行；可按需要整理段落，但原文没有称呼、落款、承诺或时间要求时不要自行添加。
            """
        case .development:
            return """
            当前内容位于开发或代码编辑环境。保持技术表达简洁准确，完整保留代码、命令、路径、文件名、参数、错误信息和专业术语；不要改写代码内容，也不要推断未提供的技术结论。
            """
        case .document:
            return """
            当前内容用于文档写作。优先改善段落结构、衔接和可读性；不要假设具体沟通对象，也不要自行添加称呼、承诺、结论或未提供的信息。
            """
        case .messaging:
            return """
            当前内容是即时聊天消息。在保留原文说话方式、亲疏程度、自然省略和分句节奏的前提下，主动改善清晰度、准确性或自然度；有明确提升空间时至少完成一处有效修改，只有原文已经自然准确时才保持不变。使用日常口语和短句，像本人直接发出的消息；礼貌不等于正式。不要改成邮件、通知、工作汇报、会议纪要或客服话术，不要为了显得完整而补主语、铺背景、加称呼、客套话、总结或下一步，也不要把一句短消息扩写成一段。
            """
        case .generic:
            return nil
        }
    }
}

struct ApplicationContext: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let role: ApplicationWritingRole

    var supportsConversationProfiles: Bool {
        role.supportsConversationProfiles
    }

    var modelInstruction: String? {
        role.modelInstruction
    }
}

enum RewriteTargetSafetyPolicy {
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "dev.warp.warp",
        "com.github.wez.wezterm",
        "org.alacritty",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper"
    ]

    static func allowsRewrite(bundleIdentifier: String) -> Bool {
        !terminalBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }

    static func blockedReason(bundleIdentifier: String) -> String? {
        guard !allowsRewrite(bundleIdentifier: bundleIdentifier) else { return nil }
        return "为避免误执行命令，Pole 不在终端中触发"
    }
}

enum ApplicationContextClassifier {
    private static let knownDisplayNames: [String: String] = [
        "com.openai.codex": "Codex",
        "com.openai.chat": "ChatGPT",
        "com.openai.chatgpt": "ChatGPT",
        "com.tencent.xinwechat": "微信",
        "com.tencent.weworkmac": "企业微信",
        "com.apple.mobilesms": "信息",
        "com.apple.mail": "邮件",
        "com.apple.dt.xcode": "Xcode",
        "com.microsoft.vscode": "Visual Studio Code",
        "com.apple.textedit": "文本编辑"
    ]

    private static let aiDevelopmentAssistantIdentifiers: Set<String> = [
        "com.openai.codex"
    ]

    private static let aiAssistantIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.chatgpt"
    ]

    private static let messagingIdentifiers: Set<String> = [
        "com.tencent.xinwechat",
        "com.tencent.weworkmac",
        "com.apple.mobilesms",
        "com.tencent.qq",
        "com.alibaba.dingtalkmac",
        "com.bytedance.macos.feishu",
        "com.larksuite.macos.lark",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "ru.keepcoder.telegram",
        "net.whatsapp.whatsapp",
        "com.hnc.discord",
        "org.whispersystems.signal-desktop"
    ]

    private static let emailIdentifiers: Set<String> = [
        "com.apple.mail",
        "com.microsoft.outlook",
        "com.readdle.smartemail-macos"
    ]

    private static let developmentIdentifiers: Set<String> = [
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "com.sublimetext.4",
        "com.github.atom"
    ]

    private static let documentIdentifiers: Set<String> = [
        "com.apple.textedit",
        "com.apple.pages",
        "com.apple.notes",
        "com.microsoft.word",
        "md.obsidian",
        "notion.id"
    ]

    static func context(
        bundleIdentifier: String,
        localizedName: String? = nil
    ) -> ApplicationContext {
        let normalizedIdentifier = bundleIdentifier.lowercased()
        let role: ApplicationWritingRole
        if aiDevelopmentAssistantIdentifiers.contains(normalizedIdentifier) {
            role = .aiDevelopmentAssistant
        } else if aiAssistantIdentifiers.contains(normalizedIdentifier) {
            role = .aiAssistant
        } else if messagingIdentifiers.contains(normalizedIdentifier) {
            role = .messaging
        } else if emailIdentifiers.contains(normalizedIdentifier) {
            role = .email
        } else if developmentIdentifiers.contains(normalizedIdentifier)
                    || normalizedIdentifier.hasPrefix("com.jetbrains.") {
            role = .development
        } else if documentIdentifiers.contains(normalizedIdentifier) {
            role = .document
        } else {
            role = .generic
        }

        let cleanName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanName.flatMap { $0.isEmpty ? nil : $0 }
            ?? knownDisplayNames[normalizedIdentifier]
            ?? bundleIdentifier
        return ApplicationContext(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            role: role
        )
    }
}

enum ApplicationContextPolicy {
    static func contextInstruction(
        for applicationContext: ApplicationContext,
        conversationInstruction: String?
    ) -> String? {
        if applicationContext.supportsConversationProfiles {
            let instructions = [
                applicationContext.modelInstruction,
                conversationInstruction
            ].compactMap { instruction -> String? in
                guard let instruction else { return nil }
                let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return instructions.isEmpty ? nil : instructions.joined(separator: "\n")
        }
        return applicationContext.modelInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

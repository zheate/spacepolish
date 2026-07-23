import Combine
import Foundation

final class AppModel: ObservableObject {
    static let defaultPrompt = PromptPolicy.currentDefault

    @Published var isEnabled: Bool
    @Published var isProcessing = false
    @Published var statusText = "就绪"
    @Published var apiKey: String
    @Published var modelName: String
    @Published var prompt: String
    @Published var triggerInterval: Double
    @Published var historyAnalysisEnabled: Bool
    @Published var rewriteLearningEnabled: Bool
    @Published var helperPath: String
    @Published var helperStatusText = "未配置"
    let conversationProfiles: ConversationProfileStore
    let intelligence: CommunicationIntelligenceStore

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        let legacyProfiles = ConversationProfileStore(defaults: defaults)
        self.conversationProfiles = legacyProfiles
        self.intelligence = CommunicationIntelligenceStore(
            defaults: defaults,
            legacyProfiles: legacyProfiles.profiles
        )
        self.isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        self.apiKey = (try? keychain.read()) ?? ""
        let savedModel = defaults.string(forKey: "modelName")
        self.modelName = savedModel == "qwen3.6-flash" ? savedModel! : "qwen3.7-plus"
        self.prompt = PromptPolicy.resolvedPrompt(from: defaults.string(forKey: "prompt"))

        let savedInterval = defaults.double(forKey: "triggerInterval")
        self.triggerInterval = savedInterval > 0 ? savedInterval : 1.2
        self.historyAnalysisEnabled = defaults.bool(forKey: "historyAnalysisEnabled")
        self.rewriteLearningEnabled = defaults.bool(forKey: "rewriteLearningEnabled")
        self.helperPath = Self.resolveHelperURL(from: defaults)?.path ?? ""
        self.helperStatusText = helperPath.isEmpty ? "未配置" : "待检测"
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func save() throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanKey.isEmpty {
            try keychain.delete()
        } else {
            try keychain.save(cleanKey)
        }

        prompt = PromptPolicy.resolvedPrompt(from: prompt)
        defaults.set(isEnabled, forKey: "isEnabled")
        defaults.set(modelName, forKey: "modelName")
        defaults.set(prompt, forKey: "prompt")
        defaults.set(triggerInterval, forKey: "triggerInterval")
        defaults.set(historyAnalysisEnabled, forKey: "historyAnalysisEnabled")
        defaults.set(rewriteLearningEnabled, forKey: "rewriteLearningEnabled")
        defaults.removeObject(forKey: "conversationHelperPath")
    }

    var helperURL: URL? {
        Self.resolveHelperURL(from: defaults)
    }

    func setHelperURL(_ url: URL?) {
        guard let url else {
            helperPath = ""
            helperStatusText = "未配置"
            defaults.removeObject(forKey: "conversationHelperBookmark")
            defaults.removeObject(forKey: "conversationHelperPath")
            return
        }
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            helperPath = ""
            helperStatusText = "无法保存 helper 授权"
            return
        }
        defaults.set(bookmark, forKey: "conversationHelperBookmark")
        defaults.removeObject(forKey: "conversationHelperPath")
        helperPath = url.path
        helperStatusText = "待检测"
    }

    private static func resolveHelperURL(from defaults: UserDefaults) -> URL? {
        guard let bookmark = defaults.data(forKey: "conversationHelperBookmark") else { return nil }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else { return nil }
        return resolved
    }
}

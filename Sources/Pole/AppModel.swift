import Combine
import Foundation

enum APIConnectionState: Equatable {
    case unknown
    case checking
    case valid
    case invalid(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let defaultPrompt = PromptPolicy.currentDefault

    @Published var isEnabled: Bool
    @Published var isProcessing = false
    @Published var statusText = "就绪"
    @Published var apiKey: String
    @Published var modelName: String
    @Published var prompt: String
    @Published var triggerInterval: Double
    @Published var soundEffectsEnabled: Bool
    @Published var enabledSemanticLibraries: Set<SemanticLibraryID>
    @Published var historyAnalysisEnabled: Bool
    @Published var rewriteLearningEnabled: Bool
    @Published var helperPath: String
    @Published var helperStatusText = "未配置"
    @Published private(set) var apiConnectionState: APIConnectionState = .unknown
    let conversationProfiles: ConversationProfileStore
    let intelligence: CommunicationIntelligenceStore

    private let defaults: UserDefaults
    private let credentialService: CredentialService
    private let helperTrustStore: HelperTrustStore
    private var pendingHistoryAnalysisPreference: Bool

    init(
        defaults: UserDefaults = .standard,
        credentialService: CredentialService = CredentialService()
    ) {
        self.defaults = defaults
        self.credentialService = credentialService
        let helperTrustStore = HelperTrustStore(defaults: defaults)
        self.helperTrustStore = helperTrustStore
        let legacyProfiles = ConversationProfileStore(defaults: defaults)
        self.conversationProfiles = legacyProfiles
        self.intelligence = CommunicationIntelligenceStore(
            defaults: defaults,
            legacyProfiles: legacyProfiles.profiles
        )
        self.isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        self.apiKey = (try? credentialService.readAPIKey()) ?? ""
        let savedModel = defaults.string(forKey: "modelName")
        self.modelName = ["qwen3.7-plus", "qwen3.6-flash"].contains(savedModel)
            ? savedModel!
            : QwenClient.defaultModel
        self.prompt = PromptPolicy.resolvedPrompt(from: defaults.string(forKey: "prompt"))

        let savedInterval = defaults.double(forKey: "triggerInterval")
        self.triggerInterval = savedInterval > 0 ? savedInterval : 1.2
        self.soundEffectsEnabled = defaults.object(forKey: "soundEffectsEnabled") as? Bool ?? true
        self.enabledSemanticLibraries = SemanticLibraryPreferences.load(from: defaults)
        let helperURL = Self.resolveHelperURL(from: defaults)
        let savedHistoryAnalysisPreference = defaults.bool(forKey: "historyAnalysisEnabled")
        self.pendingHistoryAnalysisPreference = savedHistoryAnalysisPreference
        self.historyAnalysisEnabled = helperURL != nil
            && helperTrustStore.approvedIdentity != nil
            && savedHistoryAnalysisPreference
        self.rewriteLearningEnabled = defaults.bool(forKey: "rewriteLearningEnabled")
        self.helperPath = helperURL?.path ?? ""
        if helperPath.isEmpty {
            self.helperStatusText = "未配置"
        } else if let identity = helperTrustStore.approvedIdentity {
            self.helperStatusText = identity.displaySummary
        } else {
            self.helperStatusText = "需要重新确认 helper 身份"
        }
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canUseAPI: Bool {
        guard hasAPIKey else { return false }
        switch apiConnectionState {
        case .checking, .invalid:
            return false
        case .unknown, .valid:
            return true
        }
    }

    func markAPIKeyChecking() {
        apiConnectionState = .checking
    }

    func markAPIKeyValid() {
        apiConnectionState = .valid
    }

    func markAPIKeyInvalid(_ message: String) {
        apiConnectionState = .invalid(message)
    }

    func markAPIKeyUnknown() {
        apiConnectionState = .unknown
    }

    func save() throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanKey.isEmpty {
            try credentialService.deleteAPIKey()
        } else {
            try credentialService.saveAPIKey(cleanKey)
        }

        prompt = PromptPolicy.resolvedPrompt(from: prompt)
        defaults.set(isEnabled, forKey: "isEnabled")
        defaults.set(modelName, forKey: "modelName")
        defaults.set(prompt, forKey: "prompt")
        defaults.set(triggerInterval, forKey: "triggerInterval")
        defaults.set(soundEffectsEnabled, forKey: "soundEffectsEnabled")
        SemanticLibraryPreferences.save(enabledSemanticLibraries, to: defaults)
        if helperURL == nil {
            historyAnalysisEnabled = false
            pendingHistoryAnalysisPreference = false
            defaults.set(false, forKey: "historyAnalysisEnabled")
        } else if helperNeedsConfirmation {
            defaults.set(pendingHistoryAnalysisPreference, forKey: "historyAnalysisEnabled")
        } else {
            pendingHistoryAnalysisPreference = historyAnalysisEnabled
            defaults.set(historyAnalysisEnabled, forKey: "historyAnalysisEnabled")
        }
        defaults.set(rewriteLearningEnabled, forKey: "rewriteLearningEnabled")
        defaults.removeObject(forKey: "conversationHelperPath")
    }

    var helperURL: URL? {
        Self.resolveHelperURL(from: defaults)
    }

    var approvedHelperIdentity: HelperIdentity? {
        helperTrustStore.approvedIdentity
    }

    var helperNeedsConfirmation: Bool {
        helperURL != nil && approvedHelperIdentity == nil
    }

    func setHelperURL(_ url: URL?, approvedIdentity: HelperIdentity? = nil) {
        guard let url else {
            helperPath = ""
            helperStatusText = "未配置"
            historyAnalysisEnabled = false
            defaults.set(false, forKey: "historyAnalysisEnabled")
            defaults.removeObject(forKey: "conversationHelperBookmark")
            defaults.removeObject(forKey: "conversationHelperPath")
            helperTrustStore.clear()
            pendingHistoryAnalysisPreference = false
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
        if let approvedIdentity {
            helperTrustStore.approve(approvedIdentity)
            helperStatusText = approvedIdentity.displaySummary
            historyAnalysisEnabled = pendingHistoryAnalysisPreference
        } else {
            helperTrustStore.clear()
            historyAnalysisEnabled = false
            helperStatusText = "需要确认 helper 身份"
        }
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

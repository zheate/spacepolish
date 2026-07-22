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
    let conversationProfiles: ConversationProfileStore

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        self.conversationProfiles = ConversationProfileStore(defaults: defaults)
        self.isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        self.apiKey = (try? keychain.read()) ?? ""
        let savedModel = defaults.string(forKey: "modelName")
        self.modelName = savedModel == "qwen3.6-flash" ? savedModel! : "qwen3.7-plus"
        self.prompt = PromptPolicy.resolvedPrompt(from: defaults.string(forKey: "prompt"))

        let savedInterval = defaults.double(forKey: "triggerInterval")
        self.triggerInterval = savedInterval > 0 ? savedInterval : 1.2
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
    }
}

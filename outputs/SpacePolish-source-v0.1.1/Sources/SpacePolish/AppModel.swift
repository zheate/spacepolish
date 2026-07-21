import Combine
import Foundation

final class AppModel: ObservableObject {
    static let defaultPrompt = """
    你是一名专业的中文写作编辑。请优化用户输入的表达，使其更清晰、自然、准确，同时保留原意、事实、语气、人名、数字和格式。不要补充用户没有提供的信息。只输出优化后的文本，不要解释，不要加引号。
    """

    @Published var isEnabled: Bool
    @Published var isProcessing = false
    @Published var statusText = "就绪"
    @Published var apiKey: String
    @Published var modelName: String
    @Published var prompt: String
    @Published var triggerInterval: Double

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        self.isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        self.apiKey = (try? keychain.read()) ?? ""
        self.modelName = defaults.string(forKey: "modelName") ?? "deepseek-chat"
        self.prompt = defaults.string(forKey: "prompt") ?? Self.defaultPrompt

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

        defaults.set(isEnabled, forKey: "isEnabled")
        defaults.set(modelName, forKey: "modelName")
        defaults.set(prompt, forKey: "prompt")
        defaults.set(triggerInterval, forKey: "triggerInterval")
    }
}

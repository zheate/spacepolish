import Foundation

struct QwenClient {
    static let temperature = 0.5
    static let enableThinking = false

    private let endpoint = URL(
        string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    )!

    func optimize(
        text: String,
        apiKey: String,
        model: String,
        prompt: String
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = ChatRequest(
            model: model,
            messages: [
                Message(role: "system", content: prompt),
                Message(role: "user", content: text)
            ],
            stream: false,
            temperature: Self.temperature,
            enableThinking: Self.enableThinking,
            maxTokens: 2_048
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QwenError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw QwenError.http(
                statusCode: httpResponse.statusCode,
                message: apiError?.error.message ?? "通义千问服务返回了错误"
            )
        }

        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = result.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw QwenError.emptyResult
        }
        return content
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double
    let enableThinking: Bool
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case enableThinking = "enable_thinking"
        case maxTokens = "max_tokens"
    }
}

private struct Message: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        let message: Message
    }
    let choices: [Choice]
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }
    let error: APIError
}

enum QwenError: LocalizedError {
    case invalidResponse
    case http(statusCode: Int, message: String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "没有收到有效的网络响应"
        case .http(let statusCode, let message):
            return "通义千问 API 错误（\(statusCode)）：\(message)"
        case .emptyResult:
            return "通义千问返回了空内容"
        }
    }
}

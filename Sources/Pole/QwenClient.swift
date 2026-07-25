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
        prompt: String,
        retryIssues: [String] = []
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout(
            for: text,
            isRetry: !retryIssues.isEmpty
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: [
                    Message(
                        role: "system",
                        content: Self.promptWithRetryIssues(prompt, retryIssues: retryIssues)
                    ),
                    Message(role: "user", content: text)
                ],
                stream: false,
                temperature: Self.temperature,
                enableThinking: Self.enableThinking,
                maxCompletionTokens: Self.maxCompletionTokens(for: text),
                responseFormat: nil
            )
        )

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
        return try RewriteResultPolicy.prepare(
            result.choices.first?.message.content,
            preservingBoundaryWhitespaceOf: text
        )
    }

    func optimizeStructured(
        text: String,
        apiKey: String,
        model: String,
        prompt: String,
        retryIssues: [String] = []
    ) async throws -> StructuredRewriteResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout(
            for: text,
            isRetry: !retryIssues.isEmpty
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let structuredPrompt = """
        \(Self.promptWithRetryIssues(prompt, retryIssues: retryIssues))

        只返回一个 JSON 对象，必须包含唯一字段：
        {"rewrittenText":"可直接写回的唯一改写结果"}
        不要在 JSON 外输出内容，不要输出分析、理由、事实清单或自评字段。
        """
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: [
                    Message(role: "system", content: structuredPrompt),
                    Message(role: "user", content: text)
                ],
                stream: false,
                temperature: Self.temperature,
                enableThinking: Self.enableThinking,
                maxCompletionTokens: Self.maxCompletionTokens(for: text),
                responseFormat: ResponseFormat(type: "json_object")
            )
        )

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
        let responseEnvelope = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = responseEnvelope.choices.first?.message.content,
              let jsonData = stripJSONFence(content).data(using: .utf8) else {
            throw QwenError.emptyResult
        }
        do {
            let decoded = try JSONDecoder().decode(StructuredRewriteResult.self, from: jsonData)
            let prepared = try RewriteResultPolicy.prepare(
                decoded.rewrittenText,
                preservingBoundaryWhitespaceOf: text
            )
            return StructuredRewriteResult(
                rewrittenText: prepared,
                intent: decoded.intent,
                preservedClaims: decoded.preservedClaims,
                addedClaims: decoded.addedClaims,
                certaintyChanges: decoded.certaintyChanges
            )
        } catch let error as QwenError {
            throw error
        } catch {
            throw QwenError.invalidStructuredResult
        }
    }

    private func stripJSONFence(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return trimmed }
        return lines.dropFirst().dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func promptWithRetryIssues(
        _ prompt: String,
        retryIssues: [String]
    ) -> String {
        guard !retryIssues.isEmpty else { return prompt }
        return """
        \(prompt)

        上一次候选未通过本地安全检查。必须修正以下问题，不能用解释代替改写：
        \(retryIssues.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private static func maxCompletionTokens(for text: String) -> Int {
        // Keep short chat messages from reserving an unnecessarily large output
        // budget, while allowing longer pasted text to preserve its full result.
        min(2_048, max(128, text.count * 2 + 64))
    }

    static func requestTimeout(for text: String, isRetry: Bool) -> TimeInterval {
        let initialTimeout: TimeInterval
        switch text.count {
        case ...280:
            initialTimeout = 20
        case ...1_200:
            initialTimeout = 30
        default:
            initialTimeout = 45
        }
        guard isRetry else { return initialTimeout }
        return max(12, initialTimeout * 2 / 3)
    }
}

enum RewriteResultPolicy {
    static func prepare(
        _ content: String?,
        preservingBoundaryWhitespaceOf sourceText: String
    ) throws -> String {
        guard let content,
              content.rangeOfCharacter(
                from: .whitespacesAndNewlines.inverted
              ) != nil else {
            throw QwenError.emptyResult
        }

        let resultCore = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceText.contains(where: { !$0.isWhitespace }) else {
            return resultCore
        }

        let leadingWhitespace = sourceText.prefix(while: \Character.isWhitespace)
        let trailingWhitespace = sourceText.reversed().prefix(while: \Character.isWhitespace)
        return String(leadingWhitespace)
            + resultCore
            + String(trailingWhitespace.reversed())
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double
    let enableThinking: Bool
    let maxCompletionTokens: Int
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case enableThinking = "enable_thinking"
        case maxCompletionTokens = "max_completion_tokens"
        case responseFormat = "response_format"
    }
}

private struct ResponseFormat: Encodable {
    let type: String
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
    case invalidStructuredResult

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "没有收到有效的网络响应"
        case .http(let statusCode, let message):
            return "通义千问 API 错误（\(statusCode)）：\(message)"
        case .emptyResult:
            return "通义千问返回了空内容"
        case .invalidStructuredResult:
            return "通义千问返回了无效的结构化结果"
        }
    }
}

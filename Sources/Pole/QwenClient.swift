import Foundation

struct QwenClient {
    static let defaultModel = "qwen3.7-plus"
    static let temperature = 0.5
    static let enableThinking = false

    private let endpoint = URL(
        string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    )!
    private let modelsEndpoint = URL(
        string: "https://dashscope.aliyuncs.com/compatible-mode/v1/models"
    )!

    func validateAPIKey(
        _ apiKey: String,
        model: String = Self.defaultModel
    ) async throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw QwenError.authenticationFailed
        }

        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QwenError.invalidResponse
        }
        try QwenCredentialValidationPolicy.validate(
            statusCode: httpResponse.statusCode,
            data: data,
            requiredModel: model
        )
    }

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

        let rawCore = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let resultWithoutCommentary = stripModelCommentary(
            from: rawCore,
            preservingSourceText: sourceText
        )
        let resultCore = stripTrailingEditorInstruction(
            from: resultWithoutCommentary,
            whenRequestedBy: sourceText
        )
        guard resultCore.contains(where: { !$0.isWhitespace }) else {
            throw QwenError.emptyResult
        }
        guard sourceText.contains(where: { !$0.isWhitespace }) else {
            return resultCore
        }

        let leadingWhitespace = sourceText.prefix(while: { $0.isWhitespace })
        let trailingWhitespace = sourceText.reversed().prefix(while: { $0.isWhitespace })
        return String(leadingWhitespace)
            + resultCore
            + String(trailingWhitespace.reversed())
    }

    private static func stripModelCommentary(
        from result: String,
        preservingSourceText sourceText: String
    ) -> String {
        var cleaned = result
        let leadingLabelPattern = #"^\s*(?:优化后(?:的)?(?:文本|内容)|改写(?:结果|后)?|润色(?:结果|后)?)[ \t]*[:：][ \t]*"#
        if firstMatch(of: leadingLabelPattern, in: sourceText) == nil,
           let label = firstMatch(of: leadingLabelPattern, in: cleaned),
           label.range.location == 0,
           let range = Range(label.range, in: cleaned) {
            cleaned.removeSubrange(range)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let explanationHeadingPattern = #"(?m)^[ \t]*(?:#{1,6}[ \t]*)?(?:\*{1,2})?(?:优化|修改|改写|润色|调整)(?:说明|理由|要点|点)[ \t]*[:：]?(?:\*{1,2})?[ \t]*$"#
        if firstMatch(of: explanationHeadingPattern, in: sourceText) == nil,
           let heading = firstMatch(of: explanationHeadingPattern, in: cleaned),
           heading.range.location > 0,
           let prefixRange = Range(NSRange(location: 0, length: heading.range.location), in: cleaned) {
            let prefix = cleaned[prefixRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                cleaned = prefix
            }
        }
        return cleaned
    }

    private static func stripTrailingEditorInstruction(
        from result: String,
        whenRequestedBy sourceText: String
    ) -> String {
        let pattern = #"(?:怎么优化|帮我润色|优化一下|润色一下|帮我修改|修改一下)[？?。!！\s]*$"#
        guard !sourceText.contains("讨论"),
              let sourceMatch = firstMatch(of: pattern, in: sourceText),
              sourceMatch.range.location > 0,
              let resultMatch = firstMatch(of: pattern, in: result),
              resultMatch.range.location > 0,
              let resultPrefixRange = Range(
                  NSRange(location: 0, length: resultMatch.range.location),
                  in: result
              ) else {
            return result
        }

        var cleaned = String(result[resultPrefixRange])
            .trimmingCharacters(
                in: .whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "，,；;：:")
                )
            )
        guard !cleaned.isEmpty else { return result }

        if let sourcePrefixRange = Range(
            NSRange(location: 0, length: sourceMatch.range.location),
            in: sourceText
        ) {
            let sourcePrefix = sourceText[sourcePrefixRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let terminalCharacters = CharacterSet(charactersIn: "。！？!?")
            if let terminal = sourcePrefix.unicodeScalars.last,
               terminalCharacters.contains(terminal),
               cleaned.unicodeScalars.last.map({ !terminalCharacters.contains($0) }) ?? false {
                cleaned.unicodeScalars.append(terminal)
            }
        }
        return cleaned
    }

    private static func firstMatch(
        of pattern: String,
        in text: String
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
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

private struct ModelListResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

enum QwenCredentialValidationPolicy {
    static func validate(
        statusCode: Int,
        data: Data,
        requiredModel: String
    ) throws {
        if statusCode == 401 || statusCode == 403 {
            throw QwenError.authenticationFailed
        }
        guard (200...299).contains(statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw QwenError.http(
                statusCode: statusCode,
                message: apiError?.error.message ?? "通义千问服务返回了错误"
            )
        }
        guard let response = try? JSONDecoder().decode(ModelListResponse.self, from: data) else {
            throw QwenError.invalidResponse
        }
        guard response.data.contains(where: { $0.id == requiredModel }) else {
            throw QwenError.modelUnavailable(requiredModel)
        }
    }
}

enum QwenError: LocalizedError {
    case invalidResponse
    case http(statusCode: Int, message: String)
    case authenticationFailed
    case modelUnavailable(String)
    case emptyResult
    case invalidStructuredResult

    var isAuthenticationFailure: Bool {
        switch self {
        case .authenticationFailed:
            return true
        case .http(let statusCode, _):
            return statusCode == 401 || statusCode == 403
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "没有收到有效的网络响应"
        case .http(let statusCode, let message):
            return "通义千问 API 错误（\(statusCode)）：\(message)"
        case .authenticationFailed:
            return "通义千问 API Key 无效或已失效"
        case .modelUnavailable(let model):
            return "当前 API Key 无法使用模型 \(model)"
        case .emptyResult:
            return "通义千问返回了空内容"
        case .invalidStructuredResult:
            return "通义千问返回了无效的结构化结果"
        }
    }
}

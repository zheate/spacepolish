import Darwin
import Foundation

struct HelperCapabilities: Codable, Equatable {
    static let supportedProtocolVersion = 1

    let protocolVersion: Int
    let provider: String
    let supportsSessions: Bool
    let supportsHistory: Bool
    let readOnly: Bool
}

struct HelperSession: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let type: String
    let lastActivity: Date?
}

private struct HelperSessionsResponse: Decodable {
    let protocolVersion: Int
    let status: String
    let sessions: [HelperSession]
}

private struct HelperHistoryResponse: Decodable {
    let protocolVersion: Int
    let status: String
    let messages: [ConversationMessage]
}

enum ConversationHelperError: LocalizedError, Equatable {
    case missingExecutable
    case launchFailed(String)
    case timedOut
    case outputTooLarge
    case nonzeroExit(Int32, String)
    case invalidJSON
    case incompatibleProtocol(Int)
    case notReadOnly
    case unavailable(String)
    case ambiguousSession
    case noMatchingSession

    var errorDescription: String? {
        switch self {
        case .missingExecutable: return "未找到可执行的聊天历史 helper"
        case .launchFailed(let message): return "无法启动 helper：\(message)"
        case .timedOut: return "helper 响应超时"
        case .outputTooLarge: return "helper 返回的数据超过 2 MiB 安全上限"
        case .nonzeroExit(let code, let message): return "helper 退出（\(code)）：\(message)"
        case .invalidJSON: return "helper 返回了无效 JSON"
        case .incompatibleProtocol(let version): return "不支持 helper 协议版本 \(version)"
        case .notReadOnly: return "Pole 只接受声明为只读的 helper"
        case .unavailable(let message): return "helper 当前不可用：\(message)"
        case .ambiguousSession: return "找到多个同名会话，需要用户确认"
        case .noMatchingSession: return "helper 中没有找到当前会话"
        }
    }
}

protocol ConversationContextProvider {}

protocol CurrentConversationContextProvider: ConversationContextProvider {
    func resolveCurrentConversation(mode: ConversationResolutionMode) -> ConversationSnapshot?
}

protocol ConversationHistoryProvider: ConversationContextProvider {
    func capabilities() async throws -> HelperCapabilities
    func sessions(limit: Int) async throws -> [HelperSession]
    func history(conversationID: String, limit: Int, days: Int) async throws -> [ConversationMessage]
}

struct ExternalHelperProvider: ConversationHistoryProvider {
    static let timeout: TimeInterval = 10
    static let maximumOutputBytes = 2 * 1_024 * 1_024

    let executableURL: URL
    private let runner: HelperProcessRunner

    init(executableURL: URL, runner: HelperProcessRunner = HelperProcessRunner()) {
        self.executableURL = executableURL
        self.runner = runner
    }

    func capabilities() async throws -> HelperCapabilities {
        let scopedAccess = executableURL.startAccessingSecurityScopedResource()
        defer { if scopedAccess { executableURL.stopAccessingSecurityScopedResource() } }
        let data = try await runner.run(
            executableURL: executableURL,
            arguments: ["capabilities", "--json"],
            timeout: Self.timeout,
            maximumOutputBytes: Self.maximumOutputBytes
        )
        let capabilities = try decode(HelperCapabilities.self, from: data)
        try validate(protocolVersion: capabilities.protocolVersion)
        guard capabilities.readOnly else { throw ConversationHelperError.notReadOnly }
        guard capabilities.supportsSessions, capabilities.supportsHistory else {
            throw ConversationHelperError.unavailable("缺少 sessions 或 history 能力")
        }
        return capabilities
    }

    func sessions(limit: Int = 50) async throws -> [HelperSession] {
        let clampedLimit = max(1, min(limit, 200))
        let scopedAccess = executableURL.startAccessingSecurityScopedResource()
        defer { if scopedAccess { executableURL.stopAccessingSecurityScopedResource() } }
        let data = try await runner.run(
            executableURL: executableURL,
            arguments: ["sessions", "--limit", String(clampedLimit), "--json"],
            timeout: Self.timeout,
            maximumOutputBytes: Self.maximumOutputBytes
        )
        let response = try decode(HelperSessionsResponse.self, from: data)
        try validate(protocolVersion: response.protocolVersion)
        guard response.status == "ok" else { throw ConversationHelperError.unavailable(response.status) }
        return Array(response.sessions.prefix(clampedLimit))
    }

    func history(
        conversationID: String,
        limit: Int = 200,
        days: Int = 30
    ) async throws -> [ConversationMessage] {
        let clampedLimit = max(1, min(limit, 500))
        let clampedDays = max(1, min(days, 365))
        let scopedAccess = executableURL.startAccessingSecurityScopedResource()
        defer { if scopedAccess { executableURL.stopAccessingSecurityScopedResource() } }
        let data = try await runner.run(
            executableURL: executableURL,
            arguments: [
                "history", "--conversation-id", conversationID,
                "--limit", String(clampedLimit),
                "--days", String(clampedDays),
                "--json"
            ],
            timeout: Self.timeout,
            maximumOutputBytes: Self.maximumOutputBytes
        )
        let response = try decode(HelperHistoryResponse.self, from: data)
        try validate(protocolVersion: response.protocolVersion)
        guard response.status == "ok" else { throw ConversationHelperError.unavailable(response.status) }
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(clampedDays) * 86_400)
        let filtered = response.messages.filter {
            $0.usableText != nil && $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(300)
        }.sorted { $0.timestamp < $1.timestamp }
        return Array(filtered.suffix(clampedLimit))
    }

    func resolveSession(for snapshot: ConversationSnapshot) async throws -> HelperSession {
        guard let normalizedTitle = snapshot.normalizedTitle else {
            throw ConversationHelperError.noMatchingSession
        }
        let matches = try await sessions(limit: 200).filter {
            ConversationTitleNormalizer.normalize($0.title) == normalizedTitle
        }
        guard !matches.isEmpty else { throw ConversationHelperError.noMatchingSession }
        guard matches.count == 1 else { throw ConversationHelperError.ambiguousSession }
        return matches[0]
    }

    private func validate(protocolVersion: Int) throws {
        guard protocolVersion == HelperCapabilities.supportedProtocolVersion else {
            throw ConversationHelperError.incompatibleProtocol(protocolVersion)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { valueDecoder in
            let container = try valueDecoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            return date
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ConversationHelperError.invalidJSON
        }
    }
}

struct HelperProcessRunner {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try runSynchronously(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes
            )
        }.value
    }

    private func runSynchronously(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ConversationHelperError.missingExecutable
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
            "LANG": "zh_CN.UTF-8"
        ]

        let lock = NSLock()
        var output = Data()
        var standardError = Data()
        var exceededLimit = false

        do {
            try process.run()
        } catch {
            throw ConversationHelperError.launchFailed(error.localizedDescription)
        }

        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readers.leave() }
            while let chunk = try? outputPipe.fileHandleForReading.read(upToCount: 65_536),
                  !chunk.isEmpty {
                lock.lock()
                if output.count + chunk.count > maximumOutputBytes {
                    exceededLimit = true
                    lock.unlock()
                    if process.isRunning { process.terminate() }
                    return
                }
                output.append(chunk)
                lock.unlock()
            }
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readers.leave() }
            while let chunk = try? errorPipe.fileHandleForReading.read(upToCount: 16_384),
                  !chunk.isEmpty {
                lock.lock()
                if standardError.count < 65_536 {
                    standardError.append(chunk.prefix(65_536 - standardError.count))
                }
                lock.unlock()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !exceededLimit {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let didTimeOut = process.isRunning && Date() >= deadline
        if process.isRunning {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if readers.wait(timeout: .now() + 1) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            readers.wait()
        }
        lock.lock()
        let finalOutput = output
        let finalError = standardError
        let didExceedLimit = exceededLimit || output.count > maximumOutputBytes
        lock.unlock()

        if didExceedLimit { throw ConversationHelperError.outputTooLarge }
        if didTimeOut { throw ConversationHelperError.timedOut }
        guard process.terminationStatus == 0 else {
            let message = String(data: finalError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
            throw ConversationHelperError.nonzeroExit(process.terminationStatus, message)
        }
        return finalOutput
    }
}

import Foundation

protocol TextCaptureService {
    func captureTargetText() async throws -> CapturedTextContext
}

protocol TextWritebackService {
    func replace(context: CapturedTextContext, with replacement: String) async throws
    func isCurrent(_ context: CapturedTextContext) async -> Bool
}

/// Serializes all Accessibility and keyboard-fallback I/O away from the main
/// actor. This keeps synthetic key waits and pasteboard polling from freezing
/// the menu-bar UI while preserving the existing compatibility behavior.
final class AccessibilityTextIOService: TextCaptureService, TextWritebackService,
    @unchecked Sendable {
    private let service: AccessibilityTextService
    private let queue = DispatchQueue(
        label: "com.spacepolish.text-io",
        qos: .userInitiated
    )

    init(service: AccessibilityTextService = AccessibilityTextService()) {
        self.service = service
    }

    func captureTargetText() async throws -> CapturedTextContext {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.service.captureTargetText()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func replace(context: CapturedTextContext, with replacement: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.service.replace(context: context, with: replacement)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func isCurrent(_ context: CapturedTextContext) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.service.isCurrent(context))
            }
        }
    }
}

struct ConversationContextService {
    let resolver: ConversationResolver

    init(resolver: ConversationResolver = ConversationResolver()) {
        self.resolver = resolver
    }

    func resolveCurrentConversation() async -> ConversationSnapshot? {
        await resolver.resolveCurrentConversationAsync()
    }
}

struct CredentialService {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func readAPIKey() throws -> String? { try keychain.read() }
    func saveAPIKey(_ value: String) throws { try keychain.save(value) }
    func deleteAPIKey() throws { try keychain.delete() }
}

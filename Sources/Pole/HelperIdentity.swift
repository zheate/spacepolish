import CryptoKit
import Foundation
import Security

struct HelperIdentity: Codable, Equatable {
    enum Signature: Codable, Equatable {
        case valid(identifier: String?, teamIdentifier: String?)
        case unsigned
        case invalid

        var displayText: String {
            switch self {
            case .valid(let identifier, let teamIdentifier):
                let owner = teamIdentifier ?? identifier ?? "签名身份未知"
                return "签名有效 · \(owner)"
            case .unsigned:
                return "未签名"
            case .invalid:
                return "签名无效"
            }
        }
    }

    let sha256: String
    let fileSize: UInt64
    let signature: Signature

    var shortSHA256: String {
        String(sha256.prefix(16))
    }

    var displaySummary: String {
        "\(signature.displayText) · SHA-256 \(shortSHA256)…"
    }
}

enum HelperIdentityError: LocalizedError, Equatable {
    case unreadable
    case changed
    case confirmationRequired

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "无法读取 helper 身份"
        case .changed:
            return "helper 文件已变化，请在设置中重新确认"
        case .confirmationRequired:
            return "helper 需要在设置中确认后才能运行"
        }
    }
}

struct HelperIdentityService {
    func inspect(_ executableURL: URL) async throws -> HelperIdentity {
        try await Task.detached(priority: .userInitiated) {
            try inspectSynchronously(executableURL)
        }.value
    }

    private func inspectSynchronously(_ executableURL: URL) throws -> HelperIdentity {
        guard FileManager.default.isReadableFile(atPath: executableURL.path),
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: executableURL.path
              ),
              let fileSize = attributes[.size] as? NSNumber else {
            throw HelperIdentityError.unreadable
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: executableURL)
        } catch {
            throw HelperIdentityError.unreadable
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 256 * 1_024),
                  !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HelperIdentityError.unreadable
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return HelperIdentity(
            sha256: digest,
            fileSize: fileSize.uint64Value,
            signature: signature(for: executableURL)
        )
    }

    private func signature(for executableURL: URL) -> HelperIdentity.Signature {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return .unsigned
        }

        let validity = SecStaticCodeCheckValidity(staticCode, [], nil)
        if validity == errSecCSUnsigned { return .unsigned }
        guard validity == errSecSuccess else { return .invalid }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard infoStatus == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return .valid(identifier: nil, teamIdentifier: nil)
        }
        return .valid(
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }
}

struct HelperTrustStore {
    private static let identityKey = "conversationHelperApprovedIdentity"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var approvedIdentity: HelperIdentity? {
        guard let data = defaults.data(forKey: Self.identityKey) else { return nil }
        return try? JSONDecoder().decode(HelperIdentity.self, from: data)
    }

    func approve(_ identity: HelperIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Self.identityKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.identityKey)
    }
}

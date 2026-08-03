import Foundation
import OSLog

final class RewritePerformanceTrace: @unchecked Sendable {
    enum Stage: String {
        case capture
        case conversationContext = "conversation_context"
        case historyContext = "history_context"
        case firstModel = "first_model"
        case firstGuard = "first_guard"
        case retryModel = "retry_model"
        case retryGuard = "retry_guard"
        case writeback
    }

    private static let logger = Logger(
        subsystem: "com.spacepolish.mac",
        category: "rewrite-performance"
    )

    private let action: String
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var inputLength = 0
    private var isFinished = false
    private var recordedStages: Set<Stage> = []

    init(action: String) {
        self.action = action
    }

    static func timestamp() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func setInputLength(_ length: Int) {
        lock.lock()
        inputLength = length
        lock.unlock()
    }

    func record(_ stage: Stage, since stageStartedAt: UInt64) {
        lock.lock()
        guard !recordedStages.contains(stage), !isFinished else {
            lock.unlock()
            return
        }
        recordedStages.insert(stage)
        let length = inputLength
        lock.unlock()

        let duration = Self.milliseconds(since: stageStartedAt)
        Self.logger.info(
            "action=\(self.action, privacy: .public) stage=\(stage.rawValue, privacy: .public) duration_ms=\(duration, privacy: .public) input_chars=\(length, privacy: .public)"
        )
    }

    func finish(
        outcome: String,
        retried: Bool,
        retryReason: String? = nil,
        failureReason: String? = nil,
        guardHits: [String] = []
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let length = inputLength
        lock.unlock()

        let total = Self.milliseconds(since: startedAt)
        let resolvedRetryReason = retryReason ?? "none"
        let resolvedFailureReason = failureReason ?? "none"
        let resolvedGuardHits = guardHits.isEmpty
            ? "none"
            : guardHits.joined(separator: ",")
        Self.logger.info(
            "action=\(self.action, privacy: .public) stage=total duration_ms=\(total, privacy: .public) input_chars=\(length, privacy: .public) retried=\(retried, privacy: .public) retry_reason=\(resolvedRetryReason, privacy: .public) failure_reason=\(resolvedFailureReason, privacy: .public) guard_hits=\(resolvedGuardHits, privacy: .public) outcome=\(outcome, privacy: .public)"
        )
    }

    private static func milliseconds(since startedAt: UInt64) -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        return Int(elapsed / 1_000_000)
    }
}

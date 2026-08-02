import AppKit
import ApplicationServices
import Foundation

enum RewriteCancellationReason: Equatable {
    case paused
    case applicationChanged
    case targetChanged
    case textChanged

    var statusText: String {
        switch self {
        case .paused:
            return "已暂停，当前处理已取消"
        case .applicationChanged:
            return "前台应用已切换，未写入优化结果"
        case .targetChanged:
            return "输入目标已切换，未写入优化结果"
        case .textChanged:
            return "输入内容已变化，未写入优化结果"
        }
    }

    var performanceOutcome: String {
        switch self {
        case .paused: return "cancelled_paused"
        case .applicationChanged: return "cancelled_application_changed"
        case .targetChanged: return "cancelled_target_changed"
        case .textChanged: return "cancelled_text_changed"
        }
    }
}

@MainActor
final class RewriteCoordinator {
    private(set) var currentRequestID: UUID?
    private var currentTask: Task<Void, Never>?
    private var targetMonitor: RewriteTargetMonitor?
    private var onCancellation: ((RewriteCancellationReason) -> Void)?

    var hasActiveRequest: Bool { currentRequestID != nil }

    @discardableResult
    func beginRequest(
        onCancellation: ((RewriteCancellationReason) -> Void)? = nil
    ) -> UUID {
        currentTask?.cancel()
        targetMonitor?.stop()
        let requestID = UUID()
        currentRequestID = requestID
        currentTask = nil
        targetMonitor = nil
        self.onCancellation = onCancellation
        return requestID
    }

    func attach(_ task: Task<Void, Never>, to requestID: UUID) {
        guard currentRequestID == requestID else {
            task.cancel()
            return
        }
        currentTask = task
    }

    func monitor(
        context: CapturedTextContext,
        requestID: UUID,
        onCancellation: @escaping (RewriteCancellationReason) -> Void
    ) {
        guard currentRequestID == requestID else { return }
        targetMonitor?.stop()
        self.onCancellation = onCancellation
        let monitor = RewriteTargetMonitor(context: context) { [weak self] reason in
            self?.cancel(reason)
        }
        targetMonitor = monitor
        monitor.start()
    }

    func isCurrent(_ requestID: UUID) -> Bool {
        currentRequestID == requestID && !Task.isCancelled
    }

    func prepareForCommit(_ requestID: UUID) -> Bool {
        guard currentRequestID == requestID else { return false }
        targetMonitor?.stop()
        targetMonitor = nil
        return true
    }

    func finish(_ requestID: UUID? = nil) {
        if let requestID, currentRequestID != requestID { return }
        targetMonitor?.stop()
        targetMonitor = nil
        currentTask = nil
        currentRequestID = nil
        onCancellation = nil
    }

    func cancel(_ reason: RewriteCancellationReason) {
        guard currentRequestID != nil else { return }
        let callback = onCancellation
        currentTask?.cancel()
        targetMonitor?.stop()
        targetMonitor = nil
        currentTask = nil
        currentRequestID = nil
        onCancellation = nil
        callback?(reason)
    }
}

@MainActor
private final class RewriteTargetMonitor: NSObject {
    private let context: CapturedTextContext
    private let onChange: (RewriteCancellationReason) -> Void
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?

    init(
        context: CapturedTextContext,
        onChange: @escaping (RewriteCancellationReason) -> Void
    ) {
        self.context = context
        self.onChange = onChange
        super.init()
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        let processIdentifier = context.processIdentifier
        var createdObserver: AXObserver?
        guard AXObserverCreate(
            processIdentifier,
            { _, _, notification, reference in
                guard let reference else { return }
                let monitor = Unmanaged<RewriteTargetMonitor>
                    .fromOpaque(reference)
                    .takeUnretainedValue()
                let name = notification as String
                DispatchQueue.main.async {
                    monitor.handle(notification: name)
                }
            },
            &createdObserver
        ) == .success,
              let createdObserver else {
            return
        }
        observer = createdObserver

        let application = AXUIElementCreateApplication(processIdentifier)
        let reference = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(
            createdObserver,
            application,
            kAXFocusedWindowChangedNotification as CFString,
            reference
        )
        _ = AXObserverAddNotification(
            createdObserver,
            application,
            kAXFocusedUIElementChangedNotification as CFString,
            reference
        )
        if case .accessibility(let element) = context.target {
            _ = AXObserverAddNotification(
                createdObserver,
                element,
                kAXValueChangedNotification as CFString,
                reference
            )
            _ = AXObserverAddNotification(
                createdObserver,
                element,
                kAXUIElementDestroyedNotification as CFString,
                reference
            )
        }

        let source = AXObserverGetRunLoopSource(createdObserver)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        observer = nil
    }

    private func handle(notification: String) {
        switch notification {
        case kAXValueChangedNotification:
            onChange(.textChanged)
        default:
            onChange(.targetChanged)
        }
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
              application.processIdentifier != context.processIdentifier else {
            return
        }
        onChange(.applicationChanged)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }
}

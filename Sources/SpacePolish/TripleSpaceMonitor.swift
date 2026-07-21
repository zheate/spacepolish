import ApplicationServices
import Foundation

final class TripleSpaceMonitor {
    var isEnabled: () -> Bool = { true }
    var maximumInterval: () -> Double = { 1.2 }
    var onTrigger: () -> Void = {}

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var consecutiveSpaces = 0
    private var lastSpaceTime: TimeInterval = 0

    func start() throws {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<TripleSpaceMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }
                if monitor.handleKeyDown(event) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: pointer
        ) else {
            throw MonitorError.cannotCreateEventTap
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        consecutiveSpaces = 0
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard isEnabled() else {
            consecutiveSpaces = 0
            return false
        }

        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let blockedModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        let hasBlockedModifier = !event.flags.intersection(blockedModifiers).isEmpty

        guard keyCode == 49, !isAutoRepeat, !hasBlockedModifier else {
            consecutiveSpaces = 0
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSpaceTime > maximumInterval() {
            consecutiveSpaces = 0
        }
        lastSpaceTime = now
        consecutiveSpaces += 1

        guard consecutiveSpaces == 3 else { return false }
        consecutiveSpaces = 0
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger()
        }
        return true
    }

    deinit {
        stop()
    }
}

enum MonitorError: LocalizedError {
    case cannotCreateEventTap

    var errorDescription: String? {
        "无法监听键盘。请在系统设置中授予 SpacePolish 辅助功能权限，然后重新打开应用。"
    }
}

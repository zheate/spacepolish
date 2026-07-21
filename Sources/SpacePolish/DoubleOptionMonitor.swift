import ApplicationServices
import Foundation

enum OptionKeySide: Equatable {
    case left
    case right

    init?(keyCode: Int64) {
        switch keyCode {
        case 58:
            self = .left
        case 61:
            self = .right
        default:
            return nil
        }
    }
}

struct DoubleOptionSequenceTracker {
    private var tapCount = 0
    private var lastTapTime: TimeInterval = 0
    private var lastSide: OptionKeySide?

    mutating func handleTap(
        side: OptionKeySide,
        at time: TimeInterval,
        maximumInterval: Double
    ) -> Bool {
        if side != lastSide || time - lastTapTime > maximumInterval {
            tapCount = 0
        }
        lastSide = side
        lastTapTime = time
        tapCount += 1

        guard tapCount == 2 else { return false }
        tapCount = 0
        return true
    }

    mutating func reset() {
        tapCount = 0
        lastTapTime = 0
        lastSide = nil
    }
}

final class DoubleOptionMonitor {
    var isEnabled: () -> Bool = { true }
    var maximumInterval: () -> Double = { 1.2 }
    var onTrigger: (OptionKeySide) -> Void = { _ in }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var sequenceTracker = DoubleOptionSequenceTracker()
    private var pressedOptionKeyCodes: Set<Int64> = []
    private var optionChordUsed = false

    func start() throws {
        guard eventTap == nil else { return }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
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
                let monitor = Unmanaged<DoubleOptionMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                monitor.handleEvent(type: type, event: event)
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
        resetState()
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        guard isEnabled() else {
            resetState()
            return
        }

        if type == .keyDown {
            if !pressedOptionKeyCodes.isEmpty {
                optionChordUsed = true
            }
            sequenceTracker.reset()
            return
        }

        guard type == .flagsChanged else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let side = OptionKeySide(keyCode: keyCode) else {
            if !pressedOptionKeyCodes.isEmpty {
                optionChordUsed = true
            }
            sequenceTracker.reset()
            return
        }

        if pressedOptionKeyCodes.contains(keyCode) {
            pressedOptionKeyCodes.remove(keyCode)
            guard pressedOptionKeyCodes.isEmpty else { return }

            if optionChordUsed {
                optionChordUsed = false
                sequenceTracker.reset()
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            if sequenceTracker.handleTap(
                side: side,
                at: now,
                maximumInterval: maximumInterval()
            ) {
                DispatchQueue.main.async { [weak self] in
                    self?.onTrigger(side)
                }
            }
            return
        }

        let blockedModifiers: CGEventFlags = [
            .maskCommand,
            .maskControl,
            .maskShift,
            .maskSecondaryFn
        ]
        if !event.flags.intersection(blockedModifiers).isEmpty
            || !pressedOptionKeyCodes.isEmpty {
            optionChordUsed = true
            sequenceTracker.reset()
        }
        pressedOptionKeyCodes.insert(keyCode)
    }

    private func resetState() {
        sequenceTracker.reset()
        pressedOptionKeyCodes.removeAll()
        optionChordUsed = false
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

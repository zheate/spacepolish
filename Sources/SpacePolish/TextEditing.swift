import ApplicationServices
import AppKit
import Foundation

struct TextRewritePlan: Equatable {
    let capturedText: String
    let cleanedText: String
    let cursorUTF16: Int
    let triggerRange: NSRange
    let replacementRange: NSRange
    let sourceText: String
}

enum TextRangePlanner {
    static func plan(text: String, cursorUTF16: Int) throws -> TextRewritePlan {
        let original = text as NSString
        guard cursorUTF16 >= 0,
              let triggerRange = triggerRange(in: original, cursorUTF16: cursorUTF16) else {
            throw TextEditingError.triggerSpacesUnavailable
        }

        let cleaned = original.mutableCopy() as! NSMutableString
        cleaned.deleteCharacters(in: triggerRange)
        let cleanCursor = triggerRange.location

        let prefixRange = NSRange(location: 0, length: cleanCursor)
        let lastNewline = cleaned.range(
            of: "\n",
            options: .backwards,
            range: prefixRange
        )
        let paragraphStart = lastNewline.location == NSNotFound
            ? 0
            : lastNewline.location + lastNewline.length

        let paragraphRange = NSRange(
            location: paragraphStart,
            length: cleanCursor - paragraphStart
        )
        let paragraph = cleaned.substring(with: paragraphRange) as NSString
        let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted
        let first = paragraph.rangeOfCharacter(from: nonWhitespace)
        guard first.location != NSNotFound else {
            throw TextEditingError.noTextToOptimize
        }
        let last = paragraph.rangeOfCharacter(from: nonWhitespace, options: .backwards)

        let replacementRange = NSRange(
            location: paragraphStart + first.location,
            length: last.location + last.length - first.location
        )
        let source = cleaned.substring(with: replacementRange)
        return TextRewritePlan(
            capturedText: text,
            cleanedText: cleaned as String,
            cursorUTF16: cleanCursor,
            triggerRange: triggerRange,
            replacementRange: replacementRange,
            sourceText: source
        )
    }

    private static func triggerRange(
        in text: NSString,
        cursorUTF16: Int
    ) -> NSRange? {
        let immediatelyBefore = NSRange(location: cursorUTF16 - 2, length: 2)
        if immediatelyBefore.location >= 0,
           NSMaxRange(immediatelyBefore) <= text.length,
           text.substring(with: immediatelyBefore) == "  " {
            return immediatelyBefore
        }

        let immediatelyAfter = NSRange(location: cursorUTF16, length: 2)
        if NSMaxRange(immediatelyAfter) <= text.length,
           text.substring(with: immediatelyAfter) == "  " {
            return immediatelyAfter
        }

        let trailing = NSRange(location: text.length - 2, length: 2)
        if trailing.location >= 0,
           text.substring(with: trailing) == "  " {
            return trailing
        }

        return nil
    }
}

struct TextCommitPlan: Equatable {
    let updatedText: String
    let replacementRange: NSRange
    let cursorUTF16: Int
}

enum TextCommitPlanner {
    static func plan(
        currentText: String,
        capturedText: String,
        cleanedText: String,
        triggerRange: NSRange,
        sourceRange: NSRange,
        replacement: String
    ) throws -> TextCommitPlan {
        let editRange: NSRange
        if currentText == capturedText {
            let editEnd = NSMaxRange(triggerRange)
            guard sourceRange.location <= editEnd,
                  editEnd <= (currentText as NSString).length else {
                throw TextEditingError.textChangedWhileWaiting
            }
            editRange = NSRange(
                location: sourceRange.location,
                length: editEnd - sourceRange.location
            )
        } else if currentText == cleanedText {
            editRange = sourceRange
        } else {
            throw TextEditingError.textChangedWhileWaiting
        }

        let updated = NSMutableString(string: currentText)
        updated.replaceCharacters(in: editRange, with: replacement)
        return TextCommitPlan(
            updatedText: updated as String,
            replacementRange: editRange,
            cursorUTF16: updated.length
        )
    }
}

final class CapturedTextContext {
    enum Target {
        case accessibility(AXUIElement)
        case keyboard(processIdentifier: pid_t)
    }

    let target: Target
    let capturedText: String
    let cleanedText: String
    let cursorUTF16: Int
    let triggerRange: NSRange
    let replacementRange: NSRange
    let sourceText: String

    init(target: Target, plan: TextRewritePlan) {
        self.target = target
        self.capturedText = plan.capturedText
        self.cleanedText = plan.cleanedText
        self.cursorUTF16 = plan.cursorUTF16
        self.triggerRange = plan.triggerRange
        self.replacementRange = plan.replacementRange
        self.sourceText = plan.sourceText
    }
}

struct AccessibilityTextService {
    func captureAndRemoveTriggerSpaces() throws -> CapturedTextContext {
        do {
            return try captureUsingAccessibilityWithRetry()
        } catch let error as TextEditingError {
            guard error == .noFocusedTextField || error == .unsupportedTextField,
                  KeyboardTextFallback.supportsFrontmostApplication else {
                throw error
            }
            return try KeyboardTextFallback.captureAndRemoveTriggerSpaces()
        }
    }

    private func captureUsingAccessibilityWithRetry() throws -> CapturedTextContext {
        let retryDelays: [TimeInterval] = [0, 0.02, 0.05, 0.08]
        var lastError: TextEditingError = .triggerSpacesUnavailable

        for delay in retryDelays {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            do {
                return try captureUsingAccessibility()
            } catch let error as TextEditingError {
                lastError = error
                guard error == .triggerSpacesUnavailable else { throw error }
            }
        }

        throw lastError
    }

    private func captureUsingAccessibility() throws -> CapturedTextContext {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue else {
            throw TextEditingError.noFocusedTextField
        }
        let element = focusedValue as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
              let text = valueRef as? String else {
            throw TextEditingError.unsupportedTextField
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
              let rangeRef else {
            throw TextEditingError.unsupportedTextField
        }
        let axRange = rangeRef as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetType(axRange) == .cfRange,
              AXValueGetValue(axRange, .cfRange, &selectedRange),
              selectedRange.length == 0 else {
            throw TextEditingError.unsupportedTextField
        }

        let plan = try TextRangePlanner.plan(
            text: text,
            cursorUTF16: selectedRange.location
        )

        return CapturedTextContext(target: .accessibility(element), plan: plan)
    }

    func replace(context: CapturedTextContext, with replacement: String) throws {
        switch context.target {
        case .accessibility(let element):
            try replaceUsingAccessibility(
                element: element,
                context: context,
                replacement: replacement
            )
        case .keyboard(let processIdentifier):
            try KeyboardTextFallback.replace(
                context: context,
                with: replacement,
                processIdentifier: processIdentifier
            )
        }
    }

    private func replaceUsingAccessibility(
        element: AXUIElement,
        context: CapturedTextContext,
        replacement: String
    ) throws {
        var currentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &currentRef
        ) == .success,
              let current = currentRef as? String else {
            throw TextEditingError.targetDisappeared
        }

        let commit = try TextCommitPlanner.plan(
            currentText: current,
            capturedText: context.capturedText,
            cleanedText: context.cleanedText,
            triggerRange: context.triggerRange,
            sourceRange: context.replacementRange,
            replacement: replacement
        )
        try replaceCharacters(
            on: element,
            range: commit.replacementRange,
            with: replacement,
            fallbackValue: commit.updatedText,
            finalCursor: commit.cursorUTF16
        )
        scheduleCaretRecovery(
            on: element,
            expectedValue: commit.updatedText,
            cursor: commit.cursorUTF16
        )
    }

    func insertionPointScreenRect(for context: CapturedTextContext) -> CGRect? {
        guard case .accessibility(let element) = context.target else {
            return KeyboardTextFallback.indicatorScreenRect(for: context.target)
        }

        if let caretRect = bounds(
            for: CFRange(location: context.cursorUTF16, length: 0),
            on: element
        ) {
            return caretRect
        }

        if context.cursorUTF16 > 0,
           let precedingCharacterRect = bounds(
                for: CFRange(location: context.cursorUTF16 - 1, length: 1),
                on: element
           ) {
            return CGRect(
                x: precedingCharacterRect.maxX,
                y: precedingCharacterRect.minY,
                width: 1,
                height: precedingCharacterRect.height
            )
        }

        guard let elementFrame = frame(of: element) else { return nil }
        return CGRect(
            x: max(elementFrame.minX, elementFrame.maxX - 42),
            y: max(elementFrame.minY, elementFrame.maxY - 24),
            width: 1,
            height: min(20, elementFrame.height)
        )
    }

    private func replaceCharacters(
        on element: AXUIElement,
        range: NSRange,
        with replacement: String,
        fallbackValue: String,
        finalCursor: Int
    ) throws {
        var selectedRange = CFRange(location: range.location, length: range.length)
        let rangeValue = AXValueCreate(.cfRange, &selectedRange)
        let selectedTextSucceeded = rangeValue.map {
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                $0
            ) == .success
                && AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    replacement as CFTypeRef
                ) == .success
        } ?? false

        if !selectedTextSucceeded {
            guard AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                fallbackValue as CFTypeRef
            ) == .success else {
                throw TextEditingError.readOnlyTextField
            }
        }

        try setSelection(
            on: element,
            range: CFRange(location: finalCursor, length: 0)
        )
    }

    private func bounds(for range: CFRange, on element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        ) == .success,
              let boundsRef else {
            return nil
        }

        let boundsValue = boundsRef as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(boundsValue) == .cgRect,
              AXValueGetValue(boundsValue, .cgRect, &rect),
              rect.height > 0 else {
            return nil
        }
        return rect
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionRef
        ) == .success,
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeRef
              ) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func scheduleCaretRecovery(
        on element: AXUIElement,
        expectedValue: String,
        cursor: Int
    ) {
        guard cursor > 0 else { return }
        var targetProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &targetProcessIdentifier) == .success else { return }

        let state = CaretRecoveryState()
        for delay in [0.04, 0.14, 0.35, 0.70] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !state.isFinished else { return }

                var focusedRef: CFTypeRef?
                let systemWide = AXUIElementCreateSystemWide()
                guard AXUIElementCopyAttributeValue(
                    systemWide,
                    kAXFocusedUIElementAttribute as CFString,
                    &focusedRef
                ) == .success,
                      let focusedRef else {
                    return
                }
                let focusedElement = focusedRef as! AXUIElement

                // Electron may recreate its accessibility node after replacing text.
                // Match the newly focused node by process and value instead of requiring
                // it to be the exact stale AXUIElement captured before the replacement.
                var focusedProcessIdentifier: pid_t = 0
                guard AXUIElementGetPid(
                    focusedElement,
                    &focusedProcessIdentifier
                ) == .success,
                      focusedProcessIdentifier == targetProcessIdentifier else {
                    state.isFinished = true
                    return
                }

                var valueRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    focusedElement,
                    kAXValueAttribute as CFString,
                    &valueRef
                ) == .success,
                      valueRef as? String == expectedValue else {
                    state.isFinished = true
                    return
                }

                var rangeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    focusedElement,
                    kAXSelectedTextRangeAttribute as CFString,
                    &rangeRef
                ) == .success,
                      let rangeRef,
                      CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
                    return
                }
                let rangeValue = rangeRef as! AXValue

                var currentRange = CFRange()
                guard AXValueGetValue(rangeValue, .cfRange, &currentRange) else {
                    return
                }
                if currentRange.location == cursor, currentRange.length == 0 {
                    state.isFinished = true
                    return
                }

                var desiredRange = CFRange(location: cursor, length: 0)
                guard let desiredValue = AXValueCreate(.cfRange, &desiredRange) else { return }
                _ = AXUIElementSetAttributeValue(
                    focusedElement,
                    kAXSelectedTextRangeAttribute as CFString,
                    desiredValue
                )

                // Chromium-based editors can acknowledge AX selection updates but
                // still keep the DOM selection. A real right-arrow event collapses
                // that remaining selection without changing the text.
                if currentRange.length > 0 {
                    _ = postRightArrowKey()
                }
            }
        }
    }

    private func setSelection(on element: AXUIElement, range: CFRange) throws {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success else {
            throw TextEditingError.cannotSetSelection
        }
    }
}

private final class CaretRecoveryState {
    var isFinished = false
}

@discardableResult
private func postRightArrowKey() -> Bool {
    guard let keyDown = CGEvent(
        keyboardEventSource: nil,
        virtualKey: 124,
        keyDown: true
    ),
          let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 124,
            keyDown: false
          ) else {
        return false
    }
    keyDown.flags = []
    keyUp.flags = []
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
}

private enum KeyboardTextFallback {
    private static let supportedBundleIdentifiers = ["com.tencent.xinWeChat"]

    static var supportsFrontmostApplication: Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return supportedBundleIdentifiers.contains(bundleIdentifier)
    }

    static func captureAndRemoveTriggerSpaces() throws -> CapturedTextContext {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              supportedBundleIdentifiers.contains(bundleIdentifier) else {
            throw TextEditingError.noFocusedTextField
        }

        let processIdentifier = application.processIdentifier
        let text = try readAllText(processIdentifier: processIdentifier)
        let plan = try TextRangePlanner.plan(
            text: text,
            cursorUTF16: (text as NSString).length
        )
        return CapturedTextContext(
            target: .keyboard(processIdentifier: processIdentifier),
            plan: plan
        )
    }

    static func replace(
        context: CapturedTextContext,
        with replacement: String,
        processIdentifier: pid_t
    ) throws {
        let current = try readAllText(processIdentifier: processIdentifier)
        let commit = try TextCommitPlanner.plan(
            currentText: current,
            capturedText: context.capturedText,
            cleanedText: context.cleanedText,
            triggerRange: context.triggerRange,
            sourceRange: context.replacementRange,
            replacement: replacement
        )
        try pasteAllText(commit.updatedText, processIdentifier: processIdentifier)
    }

    static func indicatorScreenRect(for target: CapturedTextContext.Target) -> CGRect? {
        guard case .keyboard(let processIdentifier) = target,
              let windowBounds = frontmostWindowBounds(processIdentifier: processIdentifier) else {
            return nil
        }

        return CGRect(
            x: windowBounds.maxX - 92,
            y: windowBounds.maxY - windowBounds.height * 0.28,
            width: 1,
            height: 20
        )
    }

    private static func readAllText(processIdentifier: pid_t) throws -> String {
        try ensureFrontmost(processIdentifier)
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        try performMenuCommand(
            titles: ["全选"],
            processIdentifier: processIdentifier
        )
        defer { try? collapseSelectionToEnd(processIdentifier: processIdentifier) }
        wait(0.06)

        let marker = "SpacePolish-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        let markerChangeCount = pasteboard.changeCount

        try performMenuCommand(
            titles: ["复制", "拷贝"],
            processIdentifier: processIdentifier
        )
        guard waitForPasteboardChange(
            pasteboard,
            after: markerChangeCount,
            timeout: 0.8
        ),
              let text = pasteboard.string(forType: .string),
              text != marker else {
            throw TextEditingError.keyboardTextUnavailable
        }

        return text
    }

    private static func pasteAllText(_ text: String, processIdentifier: pid_t) throws {
        try ensureFrontmost(processIdentifier)
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextEditingError.keyboardTextUnavailable
        }

        try performMenuCommand(
            titles: ["全选"],
            processIdentifier: processIdentifier
        )
        wait(0.06)
        try performMenuCommand(
            titles: ["粘贴"],
            processIdentifier: processIdentifier
        )
        wait(0.12)
        try collapseSelectionToEnd(processIdentifier: processIdentifier)
    }

    private static func collapseSelectionToEnd(processIdentifier: pid_t) throws {
        try ensureFrontmost(processIdentifier)

        // 微信的自绘输入框在“全选 + 复制/粘贴”后有时仍保留整段选区。
        // 这里必须投递到系统事件流；直接 postToPid 在微信 4.x 中可能被忽略。
        guard postRightArrowKey() else {
            throw TextEditingError.keyboardTextUnavailable
        }
        wait(0.04)
    }

    private static func ensureFrontmost(_ processIdentifier: pid_t) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            throw TextEditingError.targetDisappeared
        }
    }

    private static func performMenuCommand(
        titles: [String],
        processIdentifier: pid_t
    ) throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let menuBar = elementAttribute(
            kAXMenuBarAttribute as CFString,
            from: application
        ) else {
            throw TextEditingError.keyboardTextUnavailable
        }

        if pressFirstElement(titled: titles, in: menuBar, depth: 6) {
            return
        }

        for menuTitle in ["编辑", "文件"] {
            guard let menuBarItem = findElement(
                titled: [menuTitle],
                in: menuBar,
                depth: 2
            ) else {
                continue
            }

            guard AXUIElementPerformAction(
                menuBarItem,
                kAXPressAction as CFString
            ) == .success else {
                continue
            }
            wait(0.05)

            if pressFirstElement(titled: titles, in: menuBar, depth: 7) {
                return
            }

            _ = AXUIElementPerformAction(
                menuBarItem,
                kAXPressAction as CFString
            )
            wait(0.02)
        }

        throw TextEditingError.keyboardTextUnavailable
    }

    private static func pressFirstElement(
        titled titles: [String],
        in root: AXUIElement,
        depth: Int
    ) -> Bool {
        guard let element = findElement(titled: titles, in: root, depth: depth) else {
            return false
        }
        return AXUIElementPerformAction(
            element,
            kAXPressAction as CFString
        ) == .success
    }

    private static func findElement(
        titled titles: [String],
        in root: AXUIElement,
        depth: Int
    ) -> AXUIElement? {
        guard depth >= 0 else { return nil }

        if let title = stringAttribute(kAXTitleAttribute as CFString, from: root),
           titles.contains(title) {
            return root
        }

        guard depth > 0 else { return nil }
        for child in childElements(of: root) {
            if let match = findElement(
                titled: titles,
                in: child,
                depth: depth - 1
            ) {
                return match
            }
        }
        return nil
    }

    private static func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
              let children = value as? [AXUIElement] else {
            return []
        }
        return children
    }

    private static func waitForPasteboardChange(
        _ pasteboard: NSPasteboard,
        after changeCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != changeCount {
                wait(0.02)
                return true
            }
            wait(0.01)
        }
        return false
    }

    private static func wait(_ duration: TimeInterval) {
        Thread.sleep(forTimeInterval: duration)
    }

    private static func frontmostWindowBounds(processIdentifier: pid_t) -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windowInfo {
            guard window[kCGWindowOwnerPID as String] as? pid_t == processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let boundsObject = window[kCGWindowBounds as String] else {
                continue
            }
            let boundsDictionary = boundsObject as! CFDictionary
            guard let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 0,
                  bounds.height > 0 else {
                continue
            }
            return bounds
        }
        return nil
    }
}

private struct PasteboardSnapshot {
    private let itemContents: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        itemContents = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        } ?? []
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !itemContents.isEmpty else { return }

        let items = itemContents.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

enum TextEditingError: LocalizedError, Equatable {
    case noFocusedTextField
    case unsupportedTextField
    case triggerSpacesUnavailable
    case noTextToOptimize
    case readOnlyTextField
    case cannotSetSelection
    case targetDisappeared
    case textChangedWhileWaiting
    case keyboardTextUnavailable

    var errorDescription: String? {
        switch self {
        case .noFocusedTextField:
            return "没有找到正在输入的文本框"
        case .unsupportedTextField:
            return "这个输入框暂不支持直接读取文本"
        case .triggerSpacesUnavailable:
            return "没有在光标前找到触发用的两个空格"
        case .noTextToOptimize:
            return "当前段落没有可优化的文字"
        case .readOnlyTextField:
            return "这个输入框不允许修改文本"
        case .cannotSetSelection:
            return "无法恢复输入光标"
        case .targetDisappeared:
            return "原输入框已经不可用"
        case .textChangedWhileWaiting:
            return "等待 AI 时文本已被修改，因此没有覆盖你的新内容"
        case .keyboardTextUnavailable:
            return "无法读取微信输入框，请把光标放回输入区后重试"
        }
    }
}

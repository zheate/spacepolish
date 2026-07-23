import ApplicationServices
import AppKit
import Foundation

struct TextRewritePlan: Equatable {
    let capturedText: String
    let cursorUTF16: Int
    let replacementRange: NSRange
    let sourceText: String
}

enum UTF16TextRangeValidator {
    static func isValid(_ range: NSRange, in text: String) -> Bool {
        isValid(range, forLength: (text as NSString).length)
    }

    static func isValid(_ range: NSRange, forLength length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }
}

enum TextRangePlanner {
    static func plan(text: String, selectedRange: NSRange) throws -> TextRewritePlan {
        let original = text as NSString
        guard UTF16TextRangeValidator.isValid(
            selectedRange,
            forLength: original.length
        ) else {
            throw TextEditingError.cursorUnavailable
        }

        let replacementRange = selectedRange.length > 0
            ? selectedRange
            : NSRange(location: 0, length: original.length)
        let source = original.substring(with: replacementRange)
        let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted
        guard (source as NSString).rangeOfCharacter(from: nonWhitespace).location != NSNotFound else {
            throw TextEditingError.noTextToOptimize
        }

        return TextRewritePlan(
            capturedText: text,
            cursorUTF16: NSMaxRange(selectedRange),
            replacementRange: replacementRange,
            sourceText: source
        )
    }
}

enum TextSelectionResolver {
    static func resolve(
        text: String,
        copiedSelection: String?,
        accessibilityRange: NSRange?
    ) throws -> NSRange {
        let original = text as NSString

        if let accessibilityRange,
           UTF16TextRangeValidator.isValid(accessibilityRange, forLength: original.length) {
            if accessibilityRange.length == 0 {
                if copiedSelection == nil || copiedSelection?.isEmpty == true {
                    return accessibilityRange
                }
            } else {
                let rangedText = original.substring(with: accessibilityRange)
                if copiedSelection == nil || copiedSelection == rangedText {
                    return accessibilityRange
                }
            }
        }

        guard let copiedSelection, !copiedSelection.isEmpty else {
            return NSRange(location: original.length, length: 0)
        }

        let first = original.range(of: copiedSelection)
        guard first.location != NSNotFound else {
            throw TextEditingError.selectionUnavailable
        }

        let nextStart = first.location + 1
        if nextStart <= original.length {
            let second = original.range(
                of: copiedSelection,
                range: NSRange(location: nextStart, length: original.length - nextStart)
            )
            guard second.location == NSNotFound else {
                throw TextEditingError.selectionUnavailable
            }
        }
        return first
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
        sourceRange: NSRange,
        replacement: String
    ) throws -> TextCommitPlan {
        guard currentText == capturedText,
              UTF16TextRangeValidator.isValid(sourceRange, in: currentText) else {
            throw TextEditingError.textChangedWhileWaiting
        }

        let updated = NSMutableString(string: currentText)
        updated.replaceCharacters(in: sourceRange, with: replacement)
        return TextCommitPlan(
            updatedText: updated as String,
            replacementRange: sourceRange,
            cursorUTF16: sourceRange.location + (replacement as NSString).length
        )
    }
}

enum KeyboardTextCommitPlanner {
    static func plan(
        currentText: String,
        capturedText: String,
        sourceRange: NSRange,
        replacement: String
    ) throws -> TextCommitPlan {
        if currentText == capturedText {
            return try TextCommitPlanner.plan(
                currentText: currentText,
                capturedText: capturedText,
                sourceRange: sourceRange,
                replacement: replacement
            )
        }

        let capturedLength = (capturedText as NSString).length
        let isWholeField = sourceRange.location == 0 && sourceRange.length == capturedLength
        guard isWholeField,
              normalizedClipboardText(currentText) == normalizedClipboardText(capturedText) else {
            throw TextEditingError.textChangedWhileWaiting
        }

        return TextCommitPlan(
            updatedText: replacement,
            replacementRange: NSRange(location: 0, length: (currentText as NSString).length),
            cursorUTF16: (replacement as NSString).length
        )
    }

    private static func normalizedClipboardText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{2060}", with: "")
    }
}

enum KeyboardFallbackPolicy {
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.spacepolish.mac",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "com.mitchellh.ghostty"
    ]

    static func allows(bundleIdentifier: String) -> Bool {
        !excludedBundleIdentifiers.contains(bundleIdentifier)
    }
}

private enum TextInputSafety {
    static func validate(_ element: AXUIElement) throws {
        guard let subrole = stringAttribute(
            kAXSubroleAttribute as CFString,
            from: element
        ) else {
            return
        }
        if subrole == (kAXSecureTextFieldSubrole as String) {
            throw TextEditingError.sensitiveTextField
        }
    }

    static func validateFocusedElementIfAvailable() throws {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedRef else {
            return
        }
        try validate(focusedRef as! AXUIElement)
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
}

final class CapturedTextContext {
    enum Target {
        case accessibility(AXUIElement)
        case keyboard(processIdentifier: pid_t)
    }

    let target: Target
    let capturedText: String
    let cursorUTF16: Int
    let replacementRange: NSRange
    let sourceText: String

    init(target: Target, plan: TextRewritePlan) {
        self.target = target
        self.capturedText = plan.capturedText
        self.cursorUTF16 = plan.cursorUTF16
        self.replacementRange = plan.replacementRange
        self.sourceText = plan.sourceText
    }
}

private enum AccessibilityCaretLocator {
    static func screenRect(
        on element: AXUIElement,
        preferredLocation: Int? = nil,
        fallbackLocation: Int? = nil
    ) -> CGRect? {
        let location: Int
        if let preferredLocation {
            location = preferredLocation
        } else if let selectedRange = selectedTextRange(on: element) {
            location = selectedRange.location + selectedRange.length
        } else if let fallbackLocation {
            location = fallbackLocation
        } else {
            return nil
        }

        guard location >= 0 else { return nil }

        if let caretRect = bounds(
            for: CFRange(location: location, length: 0),
            on: element
        ) {
            return insertionRect(at: caretRect.minX, matching: caretRect)
        }

        // The character after the insertion point gives the correct leading edge,
        // including when the caret is at the beginning of a wrapped line.
        for length in [1, 2] {
            if let followingRect = bounds(
                for: CFRange(location: location, length: length),
                on: element
            ) {
                return insertionRect(at: followingRect.minX, matching: followingRect)
            }
        }

        // At the end of the text there is no following character. Try both one and
        // two UTF-16 code units so emoji and other surrogate pairs still resolve.
        for length in [1, 2] where location >= length {
            if let precedingRect = bounds(
                for: CFRange(location: location - length, length: length),
                on: element
            ) {
                return insertionRect(at: precedingRect.maxX, matching: precedingRect)
            }
        }

        return nil
    }

    static func focusedScreenRect(
        processIdentifier: pid_t,
        preferredLocation: Int? = nil,
        fallbackLocation: Int? = nil
    ) -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedRef else {
            return nil
        }

        let focusedElement = focusedRef as! AXUIElement
        var focusedProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(
            focusedElement,
            &focusedProcessIdentifier
        ) == .success,
              focusedProcessIdentifier == processIdentifier else {
            return nil
        }

        return screenRect(
            on: focusedElement,
            preferredLocation: preferredLocation,
            fallbackLocation: fallbackLocation
        )
    }

    private static func selectedTextRange(on element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
              let rangeRef else {
            return nil
        }

        let rangeValue = rangeRef as! AXValue
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func bounds(
        for range: CFRange,
        on element: AXUIElement
    ) -> CGRect? {
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

    private static func insertionRect(at x: CGFloat, matching rect: CGRect) -> CGRect {
        CGRect(x: x, y: rect.minY, width: 1, height: rect.height)
    }
}

struct AccessibilityTextService {
    func captureTargetText() throws -> CapturedTextContext {
        do {
            return try captureUsingAccessibility()
        } catch let error as TextEditingError {
            let canRetryWithKeyboard = error == .noFocusedTextField
                || error == .unsupportedTextField
            guard canRetryWithKeyboard,
                  KeyboardTextFallback.supportsFrontmostApplication else {
                throw error
            }
            return try KeyboardTextFallback.captureTargetText()
        }
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
        try TextInputSafety.validate(element)

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
              AXValueGetValue(axRange, .cfRange, &selectedRange) else {
            throw TextEditingError.unsupportedTextField
        }

        let plan = try TextRangePlanner.plan(
            text: text,
            selectedRange: NSRange(
                location: selectedRange.location,
                length: selectedRange.length
            )
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

    func isCurrent(_ context: CapturedTextContext) -> Bool {
        switch context.target {
        case .accessibility(let element):
            var processIdentifier: pid_t = 0
            guard AXUIElementGetPid(element, &processIdentifier) == .success,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
                return false
            }
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &valueRef
            ) == .success,
                  let currentText = valueRef as? String else {
                return false
            }
            return currentText == context.capturedText
        case .keyboard(let processIdentifier):
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
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

    func insertionPointScreenRect(
        for context: CapturedTextContext,
        cursorUTF16: Int? = nil
    ) -> CGRect? {
        switch context.target {
        case .accessibility(let element):
            if let rect = AccessibilityCaretLocator.screenRect(
                on: element,
                preferredLocation: cursorUTF16,
                fallbackLocation: context.cursorUTF16
            ) {
                return rect
            }

            var processIdentifier: pid_t = 0
            guard AXUIElementGetPid(element, &processIdentifier) == .success else {
                return nil
            }
            return AccessibilityCaretLocator.focusedScreenRect(
                processIdentifier: processIdentifier,
                preferredLocation: cursorUTF16,
                fallbackLocation: context.cursorUTF16
            )
        case .keyboard(let processIdentifier):
            return AccessibilityCaretLocator.focusedScreenRect(
                processIdentifier: processIdentifier,
                preferredLocation: cursorUTF16,
                fallbackLocation: context.cursorUTF16
            )
        }
    }

    private func replaceCharacters(
        on element: AXUIElement,
        range: NSRange,
        with replacement: String,
        fallbackValue: String,
        finalCursor: Int
    ) throws {
        // Writing the complete value first avoids creating a visible selection in
        // standard, browser and Electron text editors. Some controls expose a
        // read-only AXValue but still allow replacing AXSelectedText, so retain
        // that narrower operation as the second strategy.
        let fullValueSet = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            fallbackValue as CFTypeRef
        ) == .success

        if !fullValueSet {
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

            guard selectedTextSucceeded else {
                throw TextEditingError.readOnlyTextField
            }
        }

        try? setSelection(
            on: element,
            range: CFRange(location: finalCursor, length: 0)
        )
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
    static var supportsFrontmostApplication: Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return KeyboardFallbackPolicy.allows(bundleIdentifier: bundleIdentifier)
    }

    static func captureTargetText() throws -> CapturedTextContext {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              KeyboardFallbackPolicy.allows(bundleIdentifier: bundleIdentifier) else {
            throw TextEditingError.noFocusedTextField
        }
        try TextInputSafety.validateFocusedElementIfAvailable()

        let processIdentifier = application.processIdentifier
        let accessibilityRange = focusedSelectedRange(
            processIdentifier: processIdentifier
        )
        let copiedSelection = try copyCurrentSelection(
            processIdentifier: processIdentifier
        )
        let text = try readAllText(processIdentifier: processIdentifier)
        let selectedRange = try TextSelectionResolver.resolve(
            text: text,
            copiedSelection: copiedSelection,
            accessibilityRange: accessibilityRange
        )
        let plan = try TextRangePlanner.plan(
            text: text,
            selectedRange: selectedRange
        )
        return CapturedTextContext(
            target: .keyboard(processIdentifier: processIdentifier),
            plan: plan
        )
    }

    private static func copyCurrentSelection(processIdentifier: pid_t) throws -> String? {
        try ensureFrontmost(processIdentifier)
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        let marker = "Pole-selection-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        let markerChangeCount = pasteboard.changeCount

        try performShortcut(
            keyCode: 8,
            modifiers: .maskCommand,
            processIdentifier: processIdentifier
        )
        guard waitForPasteboardChange(
            pasteboard,
            after: markerChangeCount,
            timeout: 0.18
        ),
              let selection = pasteboard.string(forType: .string),
              selection != marker,
              !selection.isEmpty else {
            return nil
        }
        return selection
    }

    private static func focusedSelectedRange(processIdentifier: pid_t) -> NSRange? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedRef else {
            return nil
        }

        let focusedElement = focusedRef as! AXUIElement
        var focusedProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(
            focusedElement,
            &focusedProcessIdentifier
        ) == .success,
              focusedProcessIdentifier == processIdentifier else {
            return nil
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = rangeRef as! AXValue
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    static func replace(
        context: CapturedTextContext,
        with replacement: String,
        processIdentifier: pid_t
    ) throws {
        let current = try readAllText(processIdentifier: processIdentifier)
        let commit = try KeyboardTextCommitPlanner.plan(
            currentText: current,
            capturedText: context.capturedText,
            sourceRange: context.replacementRange,
            replacement: replacement
        )
        try pasteAllText(commit.updatedText, processIdentifier: processIdentifier)
    }

    private static func readAllText(processIdentifier: pid_t) throws -> String {
        try ensureFrontmost(processIdentifier)
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        try performShortcut(
            keyCode: 0,
            modifiers: .maskCommand,
            processIdentifier: processIdentifier
        )
        defer { try? collapseSelectionToEnd(processIdentifier: processIdentifier) }
        wait(0.06)

        let marker = "Pole-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        let markerChangeCount = pasteboard.changeCount

        try performShortcut(
            keyCode: 8,
            modifiers: .maskCommand,
            processIdentifier: processIdentifier
        )
        var copied = waitForPasteboardChange(
            pasteboard,
            after: markerChangeCount,
            timeout: 0.8
        )
        if !copied {
            // A few custom editors ignore synthetic shortcuts but expose menu
            // actions. Keep this compatibility path for those applications.
            try performMenuCommand(
                titles: ["全选", "Select All"],
                processIdentifier: processIdentifier
            )
            wait(0.05)
            try performMenuCommand(
                titles: ["复制", "拷贝", "Copy"],
                processIdentifier: processIdentifier
            )
            copied = waitForPasteboardChange(
                pasteboard,
                after: markerChangeCount,
                timeout: 0.4
            )
        }
        guard copied,
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

        try performShortcut(
            keyCode: 0,
            modifiers: .maskCommand,
            processIdentifier: processIdentifier
        )
        wait(0.06)
        try performShortcut(
            keyCode: 9,
            modifiers: .maskCommand,
            processIdentifier: processIdentifier
        )
        wait(0.12)
        try collapseSelectionToEnd(processIdentifier: processIdentifier)
    }

    private static func collapseSelectionToEnd(processIdentifier: pid_t) throws {
        try ensureFrontmost(processIdentifier)

        // Custom editors sometimes keep the full selection after copy/paste.
        // A right-arrow event collapses it to the end without changing text.
        guard postRightArrowKey() else {
            throw TextEditingError.keyboardTextUnavailable
        }
        wait(0.04)
    }

    private static func performShortcut(
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        processIdentifier: pid_t
    ) throws {
        try ensureFrontmost(processIdentifier)
        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: true
        ),
              let keyUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: keyCode,
                keyDown: false
              ) else {
            throw TextEditingError.keyboardTextUnavailable
        }
        keyDown.flags = modifiers
        keyUp.flags = modifiers
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
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
    case cursorUnavailable
    case noTextToOptimize
    case readOnlyTextField
    case cannotSetSelection
    case targetDisappeared
    case textChangedWhileWaiting
    case keyboardTextUnavailable
    case sensitiveTextField
    case selectionUnavailable

    var errorDescription: String? {
        switch self {
        case .noFocusedTextField:
            return "没有找到正在输入的文本框"
        case .unsupportedTextField:
            return "这个输入框暂不支持直接读取文本"
        case .cursorUnavailable:
            return "无法确定当前输入光标的位置"
        case .noTextToOptimize:
            return "当前输入框没有可优化的文字"
        case .readOnlyTextField:
            return "这个输入框不允许修改文本"
        case .cannotSetSelection:
            return "无法恢复输入光标"
        case .targetDisappeared:
            return "原输入框已经不可用"
        case .textChangedWhileWaiting:
            return "等待 AI 时文本已被修改，因此没有覆盖你的新内容"
        case .keyboardTextUnavailable:
            return "无法读取这个输入框"
        case .sensitiveTextField:
            return "为了保护隐私，密码和安全输入框不会进行优化"
        case .selectionUnavailable:
            return "无法确定所选文字在输入框中的位置"
        }
    }
}

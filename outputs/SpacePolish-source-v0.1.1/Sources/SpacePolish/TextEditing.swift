import ApplicationServices
import Foundation

struct TextRewritePlan: Equatable {
    let cleanedText: String
    let cursorUTF16: Int
    let replacementRange: NSRange
    let sourceText: String
}

enum TextRangePlanner {
    static func plan(text: String, cursorUTF16: Int) throws -> TextRewritePlan {
        let original = text as NSString
        guard cursorUTF16 >= 2, cursorUTF16 <= original.length else {
            throw TextEditingError.triggerSpacesUnavailable
        }

        let triggerRange = NSRange(location: cursorUTF16 - 2, length: 2)
        guard original.substring(with: triggerRange) == "  " else {
            throw TextEditingError.triggerSpacesUnavailable
        }

        let cleaned = original.mutableCopy() as! NSMutableString
        cleaned.deleteCharacters(in: triggerRange)
        let cleanCursor = cursorUTF16 - 2

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
            cleanedText: cleaned as String,
            cursorUTF16: cleanCursor,
            replacementRange: replacementRange,
            sourceText: source
        )
    }
}

final class CapturedTextContext {
    let element: AXUIElement
    let expectedText: String
    let replacementRange: NSRange
    let sourceText: String

    init(element: AXUIElement, plan: TextRewritePlan) {
        self.element = element
        self.expectedText = plan.cleanedText
        self.replacementRange = plan.replacementRange
        self.sourceText = plan.sourceText
    }
}

struct AccessibilityTextService {
    func captureAndRemoveTriggerSpaces() throws -> CapturedTextContext {
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

        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            plan.cleanedText as CFTypeRef
        ) == .success else {
            throw TextEditingError.readOnlyTextField
        }
        try setSelection(
            on: element,
            range: CFRange(location: plan.cursorUTF16, length: 0)
        )

        return CapturedTextContext(element: element, plan: plan)
    }

    func replace(context: CapturedTextContext, with replacement: String) throws {
        var currentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            context.element,
            kAXValueAttribute as CFString,
            &currentRef
        ) == .success,
              let current = currentRef as? String else {
            throw TextEditingError.targetDisappeared
        }

        guard current == context.expectedText else {
            throw TextEditingError.textChangedWhileWaiting
        }

        let updated = NSMutableString(string: current)
        updated.replaceCharacters(in: context.replacementRange, with: replacement)
        guard AXUIElementSetAttributeValue(
            context.element,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        ) == .success else {
            throw TextEditingError.readOnlyTextField
        }

        let cursor = context.replacementRange.location + (replacement as NSString).length
        try setSelection(
            on: context.element,
            range: CFRange(location: cursor, length: 0)
        )
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

enum TextEditingError: LocalizedError {
    case noFocusedTextField
    case unsupportedTextField
    case triggerSpacesUnavailable
    case noTextToOptimize
    case readOnlyTextField
    case cannotSetSelection
    case targetDisappeared
    case textChangedWhileWaiting

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
        }
    }
}

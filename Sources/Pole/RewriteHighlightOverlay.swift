import AppKit

struct RewriteHighlightPlan: Equatable {
    let ranges: [NSRange]

    var changeCount: Int { ranges.count }
    var hasChanges: Bool { !ranges.isEmpty }
}

enum RewriteHighlightPlanner {
    private static let maximumDetailedCharacters = 600

    static func plan(sourceText: String, outputText: String) -> RewriteHighlightPlan {
        let source = Array(sourceText)
        let output = Array(outputText)
        guard source != output else { return RewriteHighlightPlan(ranges: []) }

        var prefixCount = 0
        while prefixCount < source.count,
              prefixCount < output.count,
              source[prefixCount] == output[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < source.count - prefixCount,
              suffixCount < output.count - prefixCount,
              source[source.count - suffixCount - 1] == output[output.count - suffixCount - 1] {
            suffixCount += 1
        }

        let sourceCore = Array(source[prefixCount..<(source.count - suffixCount)])
        let outputCore = Array(output[prefixCount..<(output.count - suffixCount)])
        let outputOffsets = utf16Offsets(for: output)
        let prefixUTF16 = outputOffsets[prefixCount]

        let coreRanges: [NSRange]
        if max(sourceCore.count, outputCore.count) <= maximumDetailedCharacters {
            coreRanges = detailedRanges(source: sourceCore, output: outputCore)
        } else {
            let coreOffsets = utf16Offsets(for: outputCore)
            coreRanges = [NSRange(location: 0, length: coreOffsets.last ?? 0)]
        }

        let shifted = coreRanges.map {
            NSRange(location: $0.location + prefixUTF16, length: $0.length)
        }
        return RewriteHighlightPlan(ranges: mergeTouchingRanges(shifted))
    }

    private static func detailedRanges(
        source: [Character],
        output: [Character]
    ) -> [NSRange] {
        let sourceCount = source.count
        let outputCount = output.count
        var lcs = Array(
            repeating: Array(repeating: 0, count: outputCount + 1),
            count: sourceCount + 1
        )

        if sourceCount > 0, outputCount > 0 {
            for sourceIndex in stride(from: sourceCount - 1, through: 0, by: -1) {
                for outputIndex in stride(from: outputCount - 1, through: 0, by: -1) {
                    if source[sourceIndex] == output[outputIndex] {
                        lcs[sourceIndex][outputIndex] = lcs[sourceIndex + 1][outputIndex + 1] + 1
                    } else {
                        lcs[sourceIndex][outputIndex] = max(
                            lcs[sourceIndex + 1][outputIndex],
                            lcs[sourceIndex][outputIndex + 1]
                        )
                    }
                }
            }
        }

        var sourceIndex = 0
        var outputIndex = 0
        var changedStart: Int?
        var characterRanges: [Range<Int>] = []

        func beginChange() {
            if changedStart == nil { changedStart = outputIndex }
        }
        func finishChange() {
            guard let start = changedStart else { return }
            characterRanges.append(start..<outputIndex)
            changedStart = nil
        }

        while sourceIndex < sourceCount || outputIndex < outputCount {
            if sourceIndex < sourceCount,
               outputIndex < outputCount,
               source[sourceIndex] == output[outputIndex] {
                finishChange()
                sourceIndex += 1
                outputIndex += 1
            } else if outputIndex < outputCount,
                      (sourceIndex == sourceCount
                        || lcs[sourceIndex][outputIndex + 1]
                            >= lcs[sourceIndex + 1][outputIndex]) {
                beginChange()
                outputIndex += 1
            } else {
                beginChange()
                sourceIndex += 1
            }
        }
        finishChange()

        let outputOffsets = utf16Offsets(for: output)
        return characterRanges.map { range in
            NSRange(
                location: outputOffsets[range.lowerBound],
                length: outputOffsets[range.upperBound] - outputOffsets[range.lowerBound]
            )
        }
    }

    private static func utf16Offsets(for characters: [Character]) -> [Int] {
        var offsets = [0]
        offsets.reserveCapacity(characters.count + 1)
        for character in characters {
            offsets.append(offsets[offsets.count - 1] + String(character).utf16.count)
        }
        return offsets
    }

    private static func mergeTouchingRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        return sorted.reduce(into: [NSRange]()) { merged, range in
            guard let last = merged.last else {
                merged.append(range)
                return
            }
            if range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
    }

}

final class RewriteHighlightOverlay {
    private enum Timing {
        static let entrance: TimeInterval = 0.12
        static let hold: TimeInterval = 2.35
        static let dismissal: TimeInterval = 0.35
    }

    private static let fillColor = NSColor(
        calibratedRed: 1.0,
        green: 0.82,
        blue: 0.18,
        alpha: 0.30
    )
    private static let borderColor = NSColor(
        calibratedRed: 0.93,
        green: 0.66,
        blue: 0.04,
        alpha: 0.48
    )

    private var panels: [NSPanel] = []
    private var dismissalWorkItem: DispatchWorkItem?
    private var presentationGeneration = 0

    func show(accessibilityScreenRects: [CGRect]) {
        let converted = accessibilityScreenRects
            .prefix(16)
            .compactMap(appKitRect(from:))
        guard !converted.isEmpty else {
            hide()
            return
        }
        present(rects: converted)
    }

    func showFallback(
        at accessibilityScreenRect: CGRect?,
        changeCount: Int
    ) {
        guard let accessibilityScreenRect,
              let caretRect = appKitRect(from: accessibilityScreenRect) else {
            hide()
            return
        }

        hide()
        presentationGeneration &+= 1
        let label = NSTextField(labelWithString: "已优化 \(max(changeCount, 1)) 处")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.12, alpha: 0.92)
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 3, width: 58, height: 16)

        let content = highlightView(frame: NSRect(x: 0, y: 0, width: 74, height: 22))
        content.addSubview(label)
        let panel = makePanel(contentView: content)
        panel.setFrameOrigin(NSPoint(x: caretRect.maxX + 6, y: caretRect.midY - 11))
        panels = [panel]
        showPanels()
    }

    func hide() {
        presentationGeneration &+= 1
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private func present(rects: [NSRect]) {
        hide()
        presentationGeneration &+= 1
        panels = rects.map { rect in
            let content = highlightView(frame: NSRect(origin: .zero, size: rect.size))
            let panel = makePanel(contentView: content)
            panel.setFrame(rect, display: false)
            return panel
        }
        showPanels()
    }

    private func showPanels() {
        let generation = presentationGeneration
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for panel in panels {
            panel.alphaValue = reducesMotion ? 1 : 0
            panel.orderFrontRegardless()
        }

        if !reducesMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Timing.entrance
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panels.forEach { $0.animator().alphaValue = 1 }
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss(generation: generation, reducesMotion: reducesMotion)
        }
        dismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.hold, execute: workItem)
    }

    private func dismiss(generation: Int, reducesMotion: Bool) {
        guard generation == presentationGeneration else { return }
        dismissalWorkItem = nil
        if reducesMotion {
            panels.forEach { $0.orderOut(nil) }
            panels.removeAll()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Timing.dismissal
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panels.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            self.panels.forEach { $0.orderOut(nil) }
            self.panels.removeAll()
        }
    }

    private func highlightView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = Self.fillColor.cgColor
        view.layer?.borderColor = Self.borderColor.cgColor
        view.layer?.borderWidth = 0.5
        view.layer?.cornerRadius = min(3, frame.height / 3)
        return view
    }

    private func makePanel(contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }

    private func appKitRect(from accessibilityRect: CGRect) -> NSRect? {
        guard accessibilityRect.height > 0,
              let primaryScreen = NSScreen.screens.first else {
            return nil
        }
        let converted = NSRect(
            x: accessibilityRect.minX - 1.5,
            y: primaryScreen.frame.maxY - accessibilityRect.maxY - 1,
            width: max(accessibilityRect.width, 2) + 3,
            height: accessibilityRect.height + 2
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(converted) }) else {
            return nil
        }
        let clipped = converted.intersection(screen.frame)
        return clipped.width > 0 && clipped.height > 0 ? clipped : nil
    }

    deinit {
        dismissalWorkItem?.cancel()
        panels.forEach { $0.orderOut(nil) }
    }
}

import AppKit

enum InputProgressOperation {
    case optimization
    case translation
}

final class InputProgressIndicator {
    private enum Timing {
        static let entrance: TimeInterval = 0.14
        static let resultTransition: TimeInterval = 0.22
        static let dismissal: TimeInterval = 0.14
    }

    private var panel: NSPanel?
    private var dismissalWorkItem: DispatchWorkItem?

    func show(at accessibilityScreenRect: CGRect?) {
        hide()

        let indicatorSize = NSSize(width: 30, height: 18)
        var origin = fallbackOrigin(indicatorSize: indicatorSize)
        if let accessibilityScreenRect,
           let primaryScreen = NSScreen.screens.first {
            let caretRect = NSRect(
                x: accessibilityScreenRect.minX,
                y: primaryScreen.frame.maxY - accessibilityScreenRect.maxY,
                width: accessibilityScreenRect.width,
                height: accessibilityScreenRect.height
            )
            origin = NSPoint(
                x: caretRect.maxX + 3,
                y: caretRect.midY - indicatorSize.height / 2
            )
        }
        origin = clampedOrigin(origin, indicatorSize: indicatorSize)

        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let indicator = ProgressIndicatorView(
            frame: NSRect(origin: .zero, size: indicatorSize),
            reducesMotion: reducesMotion
        )
        let panel = NSPanel(
            contentRect: indicator.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = indicator
        panel.setFrameOrigin(origin)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        self.panel = panel
        panel.orderFrontRegardless()
        indicator.showProcessing()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Timing.entrance
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func finish(
        with outcome: OptimizationOutcome,
        operation: InputProgressOperation = .optimization
    ) {
        let state: IndicatorVisualState
        switch outcome {
        case .unchanged:
            state = .unchanged
        case .partial, .complete:
            state = .changed
        }
        let accessibilityDescription: String
        switch (operation, outcome) {
        case (.translation, _):
            accessibilityDescription = "翻译完成"
        case (.optimization, .unchanged):
            accessibilityDescription = "无需修改"
        case (.optimization, .partial), (.optimization, .complete):
            accessibilityDescription = "优化完成"
        }
        showResult(state, accessibilityDescription: accessibilityDescription)
    }

    func fail() {
        showResult(.failed, accessibilityDescription: "处理失败")
    }

    private func showResult(
        _ state: IndicatorVisualState,
        accessibilityDescription: String
    ) {
        guard let indicator = panel?.contentView as? ProgressIndicatorView else {
            hide()
            return
        }

        dismissalWorkItem?.cancel()
        indicator.showResult(state, accessibilityDescription: accessibilityDescription)

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissalWorkItem = workItem
        let delay = Timing.resultTransition + state.holdDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func dismiss() {
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        guard let panel else { return }

        (panel.contentView as? ProgressIndicatorView)?.stopAnimating()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Timing.dismissal
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            panel?.orderOut(nil)
            if let panel, self?.panel === panel {
                self?.panel = nil
            }
        }
    }

    private func fallbackOrigin(indicatorSize: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        return NSPoint(
            x: mouse.x + 8,
            y: mouse.y - indicatorSize.height / 2
        )
    }

    private func clampedOrigin(_ origin: NSPoint, indicatorSize: NSSize) -> NSPoint {
        let point = NSPoint(x: origin.x, y: origin.y)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX + 4), visibleFrame.maxX - indicatorSize.width - 4),
            y: min(max(origin.y, visibleFrame.minY + 4), visibleFrame.maxY - indicatorSize.height - 4)
        )
    }

    func hide() {
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        (panel?.contentView as? ProgressIndicatorView)?.stopAnimating()
        panel?.orderOut(nil)
        panel = nil
    }

    deinit {
        hide()
    }
}

private enum IndicatorVisualState {
    case changed
    case unchanged
    case failed

    var symbolName: String {
        switch self {
        case .changed:
            return "checkmark"
        case .unchanged:
            return "minus"
        case .failed:
            return "exclamationmark"
        }
    }

    var color: NSColor {
        switch self {
        case .changed:
            return .systemGreen
        case .unchanged:
            return NSColor.white.withAlphaComponent(0.72)
        case .failed:
            return .systemRed
        }
    }

    var holdDuration: TimeInterval {
        switch self {
        case .changed:
            return 0.65
        case .unchanged:
            return 0.85
        case .failed:
            return 1.0
        }
    }
}

private final class ProgressIndicatorView: NSView {
    private enum Timing {
        static let processingLoop: CFTimeInterval = 0.8
        static let processingStagger: CFTimeInterval = 0.12
        static let resultTransition: CFTimeInterval = 0.22
    }

    private let dots: [CALayer] = (0..<3).map { _ in CALayer() }
    private let iconView = NSImageView()
    private let reducesMotion: Bool

    init(frame frameRect: NSRect, reducesMotion: Bool) {
        self.reducesMotion = reducesMotion
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        layer?.cornerRadius = frameRect.height / 2

        let diameter: CGFloat = 4
        let gap: CGFloat = 4
        let totalWidth = diameter * 3 + gap * 2
        let startX = (frameRect.width - totalWidth) / 2
        let y = (frameRect.height - diameter) / 2

        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(
                x: startX + CGFloat(index) * (diameter + gap),
                y: y,
                width: diameter,
                height: diameter
            )
            dot.cornerRadius = diameter / 2
            dot.backgroundColor = NSColor.white.cgColor
            layer?.addSublayer(dot)
        }

        iconView.frame = NSRect(x: 9, y: 3, width: 12, height: 12)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.alphaValue = 0
        iconView.wantsLayer = true
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showProcessing() {
        stopAnimating()
        iconView.alphaValue = 0
        iconView.layer?.transform = CATransform3DIdentity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.forEach {
            $0.opacity = reducesMotion ? 0.78 : 0.32
            $0.transform = CATransform3DIdentity
        }
        CATransaction.commit()

        guard !reducesMotion else { return }

        let startTime = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.32, 1, 0.32, 0.32]
            opacity.keyTimes = [0, 0.22, 0.52, 1]

            let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
            lift.values = [0, 1.5, 0, 0]
            lift.keyTimes = [0, 0.22, 0.52, 1]

            let animation = CAAnimationGroup()
            animation.animations = [opacity, lift]
            animation.duration = Timing.processingLoop
            animation.beginTime = dot.convertTime(startTime, from: nil)
                + Double(index) * Timing.processingStagger
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(animation, forKey: "processing")
        }
    }

    func showResult(
        _ state: IndicatorVisualState,
        accessibilityDescription: String
    ) {
        stopAnimating()

        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        iconView.image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        iconView.contentTintColor = state.color
        iconView.setAccessibilityLabel(accessibilityDescription)

        if reducesMotion {
            for dot in dots {
                let startOpacity = dot.presentation()?.opacity ?? dot.opacity
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                dot.opacity = 0
                CATransaction.commit()

                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = startOpacity
                fade.toValue = 0
                fade.duration = 0.11
                fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
                dot.add(fade, forKey: "resultFade")
            }

            guard let iconLayer = iconView.layer else {
                iconView.alphaValue = 1
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            iconView.alphaValue = 1
            iconLayer.transform = CATransform3DIdentity
            CATransaction.commit()

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0, 1]
            fade.keyTimes = [0, 0.24, 1]
            fade.duration = Timing.resultTransition
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            iconLayer.add(fade, forKey: "resultTransition")
            return
        }

        for dot in dots {
            let startOpacity = dot.presentation()?.opacity ?? dot.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.opacity = 0
            dot.transform = CATransform3DMakeScale(0.72, 0.72, 1)
            CATransaction.commit()

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = startOpacity
            fade.toValue = 0
            fade.duration = 0.11
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dot.add(fade, forKey: "resultFade")
        }

        guard let iconLayer = iconView.layer else {
            iconView.alphaValue = 1
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconView.alphaValue = 1
        iconLayer.transform = CATransform3DIdentity
        CATransaction.commit()

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0, 1]
        fade.keyTimes = [0, 0.24, 1]

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.78, 0.78, 1.06, 1]
        scale.keyTimes = [0, 0.24, 0.72, 1]

        let transition = CAAnimationGroup()
        transition.animations = [fade, scale]
        transition.duration = Timing.resultTransition
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        iconLayer.add(transition, forKey: "resultTransition")
    }

    func stopAnimating() {
        dots.forEach { $0.removeAllAnimations() }
        iconView.layer?.removeAllAnimations()
    }
}

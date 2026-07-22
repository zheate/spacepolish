import AppKit

enum InputProgressOperation {
    case optimization
    case translation
}

enum InputProgressMoveStyle: Equatable {
    case immediate
    case eased
    case crossfade
}

enum InputProgressMotionPolicy {
    private static let maximumEasedDistance: CGFloat = 40
    private static let maximumEasedVerticalDelta: CGFloat = 6

    static func style(
        from current: CGPoint,
        to target: CGPoint,
        reducesMotion: Bool
    ) -> InputProgressMoveStyle {
        guard !reducesMotion else { return .immediate }

        let deltaX = target.x - current.x
        let deltaY = target.y - current.y
        let distance = sqrt(deltaX * deltaX + deltaY * deltaY)
        guard distance > 0.5 else { return .immediate }

        if distance <= maximumEasedDistance,
           abs(deltaY) <= maximumEasedVerticalDelta {
            return .eased
        }
        return .crossfade
    }
}

private enum IndicatorTiming {
    static let entrance: TimeInterval = 0.16
    static let easedMove: TimeInterval = 0.14
    static let crossfadeOut: TimeInterval = 0.07
    static let crossfadeIn: TimeInterval = 0.11
    static let resultTransition: TimeInterval = 0.32
    static let dismissal: TimeInterval = 0.14
}

final class InputProgressIndicator {
    private static let caretHorizontalGap: CGFloat = 6
    private static let indicatorSize = NSSize(width: 30, height: 18)

    private let indicator: ProgressIndicatorView
    private let panel: NSPanel
    private var dismissalWorkItem: DispatchWorkItem?
    private var presentationGeneration = 0
    private var movementGeneration = 0
    private var reducesMotion = false

    init() {
        let indicator = ProgressIndicatorView(
            frame: NSRect(origin: .zero, size: Self.indicatorSize)
        )
        self.indicator = indicator

        let panel = NSPanel(
            contentRect: indicator.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        panel.contentView = indicator
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
    }

    func show(
        at accessibilityScreenRect: CGRect?,
        operation: InputProgressOperation = .optimization
    ) {
        presentationGeneration &+= 1
        movementGeneration &+= 1
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil

        reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let initialOrigin = panelOrigin(
            for: accessibilityScreenRect,
            indicatorSize: Self.indicatorSize
        ) ?? fallbackOrigin(indicatorSize: Self.indicatorSize)
        panel.setFrameOrigin(
            clampedOrigin(initialOrigin, indicatorSize: Self.indicatorSize)
        )

        indicator.showProcessing(operation: operation, reducesMotion: reducesMotion)
        panel.alphaValue = reducesMotion ? 1 : 0
        panel.orderFrontRegardless()

        guard !reducesMotion else { return }
        animatePanelAlpha(
            to: 1,
            duration: IndicatorTiming.entrance,
            timingFunction: .easeOut
        )
    }

    func move(
        to accessibilityScreenRect: CGRect?,
        completion: @escaping () -> Void = {}
    ) {
        guard panel.isVisible,
              let accessibilityScreenRect,
              let origin = panelOrigin(
                for: accessibilityScreenRect,
                indicatorSize: panel.frame.size
              ) else {
            completion()
            return
        }

        let target = clampedOrigin(origin, indicatorSize: panel.frame.size)
        let style = InputProgressMotionPolicy.style(
            from: panel.frame.origin,
            to: target,
            reducesMotion: reducesMotion
        )

        movementGeneration &+= 1
        let generation = movementGeneration
        switch style {
        case .immediate:
            panel.setFrameOrigin(target)
            completion()
        case .eased:
            NSAnimationContext.runAnimationGroup { context in
                context.duration = IndicatorTiming.easedMove
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.22,
                    0.78,
                    0.24,
                    1
                )
                panel.animator().setFrameOrigin(target)
            } completionHandler: { [weak self] in
                guard let self,
                      self.movementGeneration == generation,
                      self.panel.isVisible else {
                    return
                }
                completion()
            }
        case .crossfade:
            animatePanelAlpha(
                to: 0.28,
                duration: IndicatorTiming.crossfadeOut,
                timingFunction: .easeIn
            ) { [weak self] in
                guard let self,
                      self.movementGeneration == generation,
                      self.panel.isVisible else {
                    return
                }
                self.panel.setFrameOrigin(target)
                self.animatePanelAlpha(
                    to: 1,
                    duration: IndicatorTiming.crossfadeIn,
                    timingFunction: .easeOut
                ) { [weak self] in
                    guard let self,
                          self.movementGeneration == generation,
                          self.panel.isVisible else {
                        return
                    }
                    completion()
                }
            }
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
        guard panel.isVisible else {
            hide()
            return
        }

        dismissalWorkItem?.cancel()
        indicator.showResult(state, accessibilityDescription: accessibilityDescription)

        let generation = presentationGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss(ifGenerationMatches: generation)
        }
        dismissalWorkItem = workItem
        let delay = IndicatorTiming.resultTransition + state.holdDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func dismiss(ifGenerationMatches generation: Int) {
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        guard presentationGeneration == generation, panel.isVisible else { return }

        movementGeneration &+= 1
        if reducesMotion {
            indicator.stopAnimating()
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        animatePanelAlpha(
            to: 0,
            duration: IndicatorTiming.dismissal,
            timingFunction: .easeIn
        ) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.indicator.stopAnimating()
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    private func animatePanelAlpha(
        to alpha: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunctionName,
        completion: @escaping () -> Void = {}
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timingFunction)
            panel.animator().alphaValue = alpha
        } completionHandler: {
            completion()
        }
    }

    private func fallbackOrigin(indicatorSize: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        return NSPoint(
            x: mouse.x + 8,
            y: mouse.y - indicatorSize.height / 2
        )
    }

    private func panelOrigin(
        for accessibilityScreenRect: CGRect?,
        indicatorSize: NSSize
    ) -> NSPoint? {
        guard let accessibilityScreenRect,
              let primaryScreen = NSScreen.screens.first else {
            return nil
        }
        let caretRect = NSRect(
            x: accessibilityScreenRect.minX,
            y: primaryScreen.frame.maxY - accessibilityScreenRect.maxY,
            width: accessibilityScreenRect.width,
            height: accessibilityScreenRect.height
        )
        return NSPoint(
            x: caretRect.maxX + Self.caretHorizontalGap,
            y: caretRect.midY - indicatorSize.height / 2
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
        presentationGeneration &+= 1
        movementGeneration &+= 1
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        indicator.stopAnimating()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    deinit {
        dismissalWorkItem?.cancel()
        indicator.stopAnimating()
        panel.orderOut(nil)
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
            return NSColor(calibratedWhite: 0.82, alpha: 1)
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
        static let optimizationLoop: CFTimeInterval = 1.16
        static let translationLoop: CFTimeInterval = 1.24
        static let convergence: CFTimeInterval = 0.20
    }

    private struct LayerSnapshot {
        let position: CGPoint
        let opacity: Float
        let scale: CGFloat
        let backgroundColor: CGColor?
    }

    private let dots: [CALayer] = (0..<3).map { _ in CALayer() }
    private let sparkLayer = CALayer()
    private let iconView = NSImageView()
    private var restingPositions: [CGPoint] = []
    private var reducesMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 0.94).cgColor
        layer?.cornerRadius = frameRect.height / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        sparkLayer.frame = CGRect(x: 11, y: 5, width: 8, height: 8)
        sparkLayer.cornerRadius = 4
        sparkLayer.opacity = 0
        layer?.addSublayer(sparkLayer)

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
            restingPositions.append(dot.position)
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

    func showProcessing(
        operation: InputProgressOperation,
        reducesMotion: Bool
    ) {
        stopAnimating()
        self.reducesMotion = reducesMotion
        setAccessibilityLabel(operation == .translation ? "正在翻译" : "正在优化")

        iconView.image = nil
        iconView.alphaValue = 0
        iconView.layer?.transform = CATransform3DIdentity

        let colors = processingColors(for: operation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.position = restingPositions[index]
            dot.opacity = reducesMotion ? 0.78 : 0.48
            dot.transform = CATransform3DIdentity
            dot.backgroundColor = colors[index]
        }
        sparkLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        sparkLayer.opacity = 0
        sparkLayer.transform = CATransform3DIdentity
        sparkLayer.backgroundColor = operation == .translation
            ? NSColor.systemCyan.withAlphaComponent(0.34).cgColor
            : NSColor.systemPurple.withAlphaComponent(0.34).cgColor
        CATransaction.commit()

        guard !reducesMotion else { return }
        animateAppearance()
        switch operation {
        case .optimization:
            showOptimizationProcessing()
        case .translation:
            showTranslationProcessing()
        }
    }

    private func processingColors(for operation: InputProgressOperation) -> [CGColor] {
        switch operation {
        case .optimization:
            return [
                NSColor(calibratedWhite: 0.78, alpha: 1).cgColor,
                NSColor.white.cgColor,
                NSColor(calibratedWhite: 0.78, alpha: 1).cgColor
            ]
        case .translation:
            return [
                NSColor.systemCyan.cgColor,
                NSColor.white.cgColor,
                NSColor.systemBlue.cgColor
            ]
        }
    }

    private func animateAppearance() {
        guard let layer else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.96
        scale.toValue = 1
        scale.duration = IndicatorTiming.entrance
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "appearance")
    }

    private func showOptimizationProcessing() {
        let keyTimes: [NSNumber] = [0, 0.28, 0.50, 0.72, 1]
        let startTime = CACurrentMediaTime()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        for (index, dot) in dots.enumerated() {
            let base = restingPositions[index]
            let softApproach = CGPoint(
                x: base.x + (center.x - base.x) * 0.14,
                y: center.y
            )
            let closeApproach = CGPoint(
                x: base.x + (center.x - base.x) * 0.28,
                y: center.y
            )
            let position = makeKeyframe(
                keyPath: "position",
                values: [
                    NSValue(point: base),
                    NSValue(point: softApproach),
                    NSValue(point: closeApproach),
                    NSValue(point: softApproach),
                    NSValue(point: base)
                ],
                keyTimes: keyTimes
            )
            let opacityValues: [Any] = index == 1
                ? [0.58, 0.72, 0.96, 0.72, 0.58]
                : [0.42, 0.58, 0.80, 0.58, 0.42]
            let opacity = makeKeyframe(
                keyPath: "opacity",
                values: opacityValues,
                keyTimes: keyTimes
            )
            let scaleValues: [Any] = index == 1
                ? [0.96, 1.0, 1.14, 1.0, 0.96]
                : [1.0, 1.0, 1.0, 1.0, 1.0]
            let scale = makeKeyframe(
                keyPath: "transform.scale",
                values: scaleValues,
                keyTimes: keyTimes
            )
            addLoop(
                [position, opacity, scale],
                to: dot,
                duration: Timing.optimizationLoop,
                startTime: startTime
            )
        }

        let glowOpacity = makeKeyframe(
            keyPath: "opacity",
            values: [0, 0.03, 0.18, 0.03, 0],
            keyTimes: keyTimes
        )
        let glowScale = makeKeyframe(
            keyPath: "transform.scale",
            values: [0.68, 0.82, 1.28, 0.82, 0.68],
            keyTimes: keyTimes
        )
        addLoop(
            [glowOpacity, glowScale],
            to: sparkLayer,
            duration: Timing.optimizationLoop,
            startTime: startTime
        )
    }

    private func showTranslationProcessing() {
        let keyTimes: [NSNumber] = [0, 0.24, 0.50, 0.76, 1]
        let startTime = CACurrentMediaTime()
        let left = restingPositions[0]
        let center = restingPositions[1]
        let right = restingPositions[2]
        let arcHeight: CGFloat = 0.9

        let paths: [[CGPoint]] = [
            [
                left,
                CGPoint(x: center.x, y: center.y + arcHeight),
                right,
                CGPoint(x: center.x, y: center.y - arcHeight),
                left
            ],
            [center, center, center, center, center],
            [
                right,
                CGPoint(x: center.x, y: center.y - arcHeight),
                left,
                CGPoint(x: center.x, y: center.y + arcHeight),
                right
            ]
        ]

        for (index, dot) in dots.enumerated() {
            let position = makeKeyframe(
                keyPath: "position",
                values: paths[index].map { NSValue(point: $0) },
                keyTimes: keyTimes
            )
            let opacityValues: [Any] = index == 1
                ? [0.62, 0.70, 0.82, 0.70, 0.62]
                : [0.68, 0.90, 0.82, 0.90, 0.68]
            let opacity = makeKeyframe(
                keyPath: "opacity",
                values: opacityValues,
                keyTimes: keyTimes
            )
            let scaleValues: [Any] = index == 1
                ? [0.94, 0.98, 1.06, 0.98, 0.94]
                : [0.94, 1.02, 0.98, 1.02, 0.94]
            let scale = makeKeyframe(
                keyPath: "transform.scale",
                values: scaleValues,
                keyTimes: keyTimes
            )
            addLoop(
                [position, opacity, scale],
                to: dot,
                duration: Timing.translationLoop,
                startTime: startTime
            )
        }

        let glowOpacity = makeKeyframe(
            keyPath: "opacity",
            values: [0.02, 0.12, 0.04, 0.12, 0.02],
            keyTimes: keyTimes
        )
        let glowScale = makeKeyframe(
            keyPath: "transform.scale",
            values: [0.72, 1.02, 0.82, 1.02, 0.72],
            keyTimes: keyTimes
        )
        addLoop(
            [glowOpacity, glowScale],
            to: sparkLayer,
            duration: Timing.translationLoop,
            startTime: startTime
        )
    }

    private func makeKeyframe(
        keyPath: String,
        values: [Any],
        keyTimes: [NSNumber]
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        let smoothTiming = CAMediaTimingFunction(
            controlPoints: 0.37,
            0,
            0.63,
            1
        )
        animation.timingFunctions = Array(
            repeating: smoothTiming,
            count: max(values.count - 1, 0)
        )
        return animation
    }

    private func addLoop(
        _ animations: [CAAnimation],
        to layer: CALayer,
        duration: CFTimeInterval,
        startTime: CFTimeInterval
    ) {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.beginTime = layer.convertTime(startTime, from: nil)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "processing")
    }

    func showResult(
        _ state: IndicatorVisualState,
        accessibilityDescription: String
    ) {
        let dotSnapshots = dots.map(snapshot)
        let sparkSnapshot = snapshot(sparkLayer)
        freezeProcessingLayers(dotSnapshots: dotSnapshots, sparkSnapshot: sparkSnapshot)

        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        iconView.image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        iconView.contentTintColor = state.color
        iconView.setAccessibilityLabel(accessibilityDescription)
        setAccessibilityLabel(accessibilityDescription)

        if reducesMotion {
            showReducedMotionResult(dotSnapshots: dotSnapshots)
        } else {
            showConvergingResult(
                state,
                dotSnapshots: dotSnapshots,
                sparkSnapshot: sparkSnapshot
            )
        }
    }

    private func snapshot(_ layer: CALayer) -> LayerSnapshot {
        let visible = layer.presentation() ?? layer
        return LayerSnapshot(
            position: visible.position,
            opacity: visible.opacity,
            scale: CGFloat(visible.transform.m11),
            backgroundColor: visible.backgroundColor
        )
    }

    private func freezeProcessingLayers(
        dotSnapshots: [LayerSnapshot],
        sparkSnapshot: LayerSnapshot
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (dot, snapshot) in zip(dots, dotSnapshots) {
            dot.removeAllAnimations()
            dot.position = snapshot.position
            dot.opacity = snapshot.opacity
            dot.transform = CATransform3DMakeScale(snapshot.scale, snapshot.scale, 1)
            dot.backgroundColor = snapshot.backgroundColor
        }
        sparkLayer.removeAllAnimations()
        sparkLayer.position = sparkSnapshot.position
        sparkLayer.opacity = sparkSnapshot.opacity
        sparkLayer.transform = CATransform3DMakeScale(
            sparkSnapshot.scale,
            sparkSnapshot.scale,
            1
        )
        sparkLayer.backgroundColor = sparkSnapshot.backgroundColor
        layer?.removeAnimation(forKey: "appearance")
        iconView.layer?.removeAllAnimations()
        iconView.alphaValue = 0
        CATransaction.commit()
    }

    private func showReducedMotionResult(dotSnapshots: [LayerSnapshot]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.forEach { $0.opacity = 0 }
        sparkLayer.opacity = 0
        iconView.alphaValue = 1
        CATransaction.commit()

        for (dot, snapshot) in zip(dots, dotSnapshots) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = snapshot.opacity
            fade.toValue = 0
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dot.add(fade, forKey: "resultFade")
        }

        guard let iconLayer = iconView.layer else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0, 1]
        fade.keyTimes = [0, 0.42, 1]
        fade.duration = IndicatorTiming.resultTransition
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        iconLayer.add(fade, forKey: "resultTransition")
    }

    private func showConvergingResult(
        _ state: IndicatorVisualState,
        dotSnapshots: [LayerSnapshot],
        sparkSnapshot: LayerSnapshot
    ) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let finalScale: CGFloat = 0.38
        let resultColor = state.color.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots {
            dot.position = center
            dot.opacity = 0
            dot.transform = CATransform3DMakeScale(finalScale, finalScale, 1)
            dot.backgroundColor = resultColor
        }
        sparkLayer.position = center
        sparkLayer.opacity = 0
        sparkLayer.transform = CATransform3DMakeScale(0.62, 0.62, 1)
        sparkLayer.backgroundColor = resultColor
        iconView.alphaValue = 1
        iconView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        for (dot, snapshot) in zip(dots, dotSnapshots) {
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: snapshot.position)
            position.toValue = NSValue(point: center)

            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = snapshot.opacity
            opacity.toValue = 0

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = snapshot.scale
            scale.toValue = finalScale

            let color = CABasicAnimation(keyPath: "backgroundColor")
            color.fromValue = snapshot.backgroundColor
            color.toValue = resultColor

            let convergence = CAAnimationGroup()
            convergence.animations = [position, opacity, scale, color]
            convergence.duration = Timing.convergence
            convergence.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(convergence, forKey: "resultConvergence")
        }

        let sparkOpacity = makeKeyframe(
            keyPath: "opacity",
            values: [sparkSnapshot.opacity, 0.22, 0],
            keyTimes: [0, 0.42, 1]
        )
        let sparkScale = makeKeyframe(
            keyPath: "transform.scale",
            values: [sparkSnapshot.scale, 1.10, 0.62],
            keyTimes: [0, 0.42, 1]
        )
        let sparkColor = CABasicAnimation(keyPath: "backgroundColor")
        sparkColor.fromValue = sparkSnapshot.backgroundColor
        sparkColor.toValue = resultColor

        let sparkTransition = CAAnimationGroup()
        sparkTransition.animations = [sparkOpacity, sparkScale, sparkColor]
        sparkTransition.duration = Timing.convergence
        sparkTransition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sparkLayer.add(sparkTransition, forKey: "resultBridge")

        guard let iconLayer = iconView.layer else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0, 0.72, 1]
        fade.keyTimes = [0, 0.44, 0.78, 1]

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.72, 0.72, 1.03, 1]
        scale.keyTimes = [0, 0.44, 0.80, 1]

        let transition = CAAnimationGroup()
        transition.animations = [fade, scale]
        transition.duration = IndicatorTiming.resultTransition
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        iconLayer.add(transition, forKey: "resultTransition")
    }

    func stopAnimating() {
        dots.forEach { $0.removeAllAnimations() }
        sparkLayer.removeAllAnimations()
        iconView.layer?.removeAllAnimations()
        layer?.removeAllAnimations()
    }
}

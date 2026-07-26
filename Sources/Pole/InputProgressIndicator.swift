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

    @discardableResult
    func show(
        at accessibilityScreenRect: CGRect?,
        operation: InputProgressOperation = .optimization
    ) -> Bool {
        presentationGeneration &+= 1
        movementGeneration &+= 1
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil

        reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let initialOrigin = panelOrigin(
            for: accessibilityScreenRect,
            indicatorSize: Self.indicatorSize
        ) else {
            hide()
            return false
        }
        panel.setFrameOrigin(
            clampedOrigin(initialOrigin, indicatorSize: Self.indicatorSize)
        )

        indicator.showProcessing(operation: operation, reducesMotion: reducesMotion)
        panel.alphaValue = reducesMotion ? 1 : 0
        panel.orderFrontRegardless()

        guard !reducesMotion else { return true }
        animatePanelAlpha(
            to: 1,
            duration: IndicatorTiming.entrance,
            timingFunction: .easeOut
        )
        return true
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
        static let optimizationLoop: CFTimeInterval = 1.12
        static let translationLoop: CFTimeInterval = 1.04
        static let convergence: CFTimeInterval = 0.20
    }

    private struct LayerSnapshot {
        let position: CGPoint
        let opacity: Float
        let scale: CGFloat
        let backgroundColor: CGColor?
    }

    private let processingBarLayer = CALayer()
    private let shimmerLayer = CAGradientLayer()
    private let iconView = NSImageView()
    private var reducesMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 0.94).cgColor
        layer?.cornerRadius = frameRect.height / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        processingBarLayer.frame = CGRect(x: 9, y: 7, width: 12, height: 4)
        processingBarLayer.cornerRadius = 2
        processingBarLayer.masksToBounds = true
        processingBarLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(processingBarLayer)

        shimmerLayer.frame = CGRect(x: -8, y: 0, width: 8, height: 4)
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.cornerRadius = 2
        processingBarLayer.addSublayer(shimmerLayer)

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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        processingBarLayer.opacity = reducesMotion ? 0.82 : 0.70
        processingBarLayer.transform = CATransform3DIdentity
        processingBarLayer.backgroundColor = processingTrackColor(for: operation)
        shimmerLayer.opacity = reducesMotion ? 0.54 : 0
        shimmerLayer.transform = CATransform3DIdentity
        shimmerLayer.position = CGPoint(x: reducesMotion ? 6 : -4, y: 2)
        shimmerLayer.colors = processingShimmerColors(for: operation)
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

    private func processingTrackColor(for operation: InputProgressOperation) -> CGColor {
        switch operation {
        case .optimization:
            return NSColor.systemPurple.withAlphaComponent(0.34).cgColor
        case .translation:
            return NSColor.systemCyan.withAlphaComponent(0.34).cgColor
        }
    }

    private func processingShimmerColors(for operation: InputProgressOperation) -> [CGColor] {
        switch operation {
        case .optimization:
            return [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0.96).cgColor,
                NSColor.systemPurple.withAlphaComponent(0).cgColor
            ]
        case .translation:
            return [
                NSColor.systemCyan.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0.96).cgColor,
                NSColor.systemBlue.withAlphaComponent(0).cgColor
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
        showShimmerProcessing(
            duration: Timing.optimizationLoop,
            trackOpacity: [0.62, 0.78, 0.68, 0.62],
            trackScale: [0.98, 1.02, 1.0, 0.98]
        )
    }

    private func showTranslationProcessing() {
        showShimmerProcessing(
            duration: Timing.translationLoop,
            trackOpacity: [0.66, 0.82, 0.72, 0.66],
            trackScale: [0.99, 1.01, 1.0, 0.99]
        )
    }

    private func showShimmerProcessing(
        duration: CFTimeInterval,
        trackOpacity: [Any],
        trackScale: [Any]
    ) {
        let startTime = CACurrentMediaTime()
        let shimmerPosition = makeKeyframe(
            keyPath: "position.x",
            values: [-4, 0, 12, 16],
            keyTimes: [0, 0.16, 0.78, 1]
        )
        let shimmerOpacity = makeKeyframe(
            keyPath: "opacity",
            values: [0, 0.92, 0.92, 0],
            keyTimes: [0, 0.16, 0.78, 1]
        )
        addLoop(
            [shimmerPosition, shimmerOpacity],
            to: shimmerLayer,
            duration: duration,
            startTime: startTime
        )

        let barOpacity = makeKeyframe(
            keyPath: "opacity",
            values: trackOpacity,
            keyTimes: [0, 0.30, 0.72, 1]
        )
        let barScale = makeKeyframe(
            keyPath: "transform.scale",
            values: trackScale,
            keyTimes: [0, 0.30, 0.72, 1]
        )
        addLoop(
            [barOpacity, barScale],
            to: processingBarLayer,
            duration: duration,
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
        let barSnapshot = snapshot(processingBarLayer)
        freezeProcessingLayers(barSnapshot: barSnapshot)

        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        iconView.image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        iconView.contentTintColor = state.color
        iconView.setAccessibilityLabel(accessibilityDescription)
        setAccessibilityLabel(accessibilityDescription)

        if reducesMotion {
            showReducedMotionResult(barSnapshot: barSnapshot)
        } else {
            showConvergingResult(
                state,
                barSnapshot: barSnapshot
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

    private func freezeProcessingLayers(barSnapshot: LayerSnapshot) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        processingBarLayer.removeAllAnimations()
        processingBarLayer.position = barSnapshot.position
        processingBarLayer.opacity = barSnapshot.opacity
        processingBarLayer.transform = CATransform3DMakeScale(
            barSnapshot.scale,
            barSnapshot.scale,
            1
        )
        processingBarLayer.backgroundColor = barSnapshot.backgroundColor
        shimmerLayer.removeAllAnimations()
        shimmerLayer.opacity = 0
        layer?.removeAnimation(forKey: "appearance")
        iconView.layer?.removeAllAnimations()
        iconView.alphaValue = 0
        CATransaction.commit()
    }

    private func showReducedMotionResult(barSnapshot: LayerSnapshot) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        processingBarLayer.opacity = 0
        iconView.alphaValue = 1
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = barSnapshot.opacity
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        processingBarLayer.add(fade, forKey: "resultFade")

        guard let iconLayer = iconView.layer else { return }
        let iconFade = CAKeyframeAnimation(keyPath: "opacity")
        iconFade.values = [0, 0, 1]
        iconFade.keyTimes = [0, 0.42, 1]
        iconFade.duration = IndicatorTiming.resultTransition
        iconFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        iconLayer.add(iconFade, forKey: "resultTransition")
    }

    private func showConvergingResult(
        _ state: IndicatorVisualState,
        barSnapshot: LayerSnapshot
    ) {
        let resultColor = state.color.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        processingBarLayer.opacity = 0
        processingBarLayer.transform = CATransform3DMakeScale(0.16, 0.72, 1)
        processingBarLayer.backgroundColor = resultColor
        iconView.alphaValue = 1
        iconView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        let barOpacity = CABasicAnimation(keyPath: "opacity")
        barOpacity.fromValue = barSnapshot.opacity
        barOpacity.toValue = 0

        let barScaleX = CABasicAnimation(keyPath: "transform.scale.x")
        barScaleX.fromValue = barSnapshot.scale
        barScaleX.toValue = 0.16

        let barScaleY = CABasicAnimation(keyPath: "transform.scale.y")
        barScaleY.fromValue = barSnapshot.scale
        barScaleY.toValue = 0.72

        let barColor = CABasicAnimation(keyPath: "backgroundColor")
        barColor.fromValue = barSnapshot.backgroundColor
        barColor.toValue = resultColor

        let convergence = CAAnimationGroup()
        convergence.animations = [barOpacity, barScaleX, barScaleY, barColor]
        convergence.duration = Timing.convergence
        convergence.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        processingBarLayer.add(convergence, forKey: "resultConvergence")

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
        processingBarLayer.removeAllAnimations()
        shimmerLayer.removeAllAnimations()
        iconView.layer?.removeAllAnimations()
        layer?.removeAllAnimations()
    }
}

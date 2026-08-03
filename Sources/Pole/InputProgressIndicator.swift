import AppKit

enum InputProgressPalette {
    // A balanced success green that stays legible after the dark backing
    // surface fades away, including over white document backgrounds.
    static let completion = NSColor(
        calibratedRed: 22 / 255,
        green: 138 / 255,
        blue: 69 / 255,
        alpha: 1
    )
}

enum InputProgressOperation {
    case optimization
    case translation
}

enum InputProgressSoundCue: Equatable {
    case completion
    case unchanged
    case failure

    static func result(
        for outcome: OptimizationOutcome,
        operation: InputProgressOperation
    ) -> InputProgressSoundCue {
        return outcome == .unchanged ? .unchanged : .completion
    }
}

private enum IndicatorTiming {
    static let entrance: TimeInterval = 0.16
    static let resultTransition: TimeInterval = 0.32
    static let checkedAnimation: TimeInterval = 2.2
    static let alertAnimation: TimeInterval = 80 / 29.9700012207031
    static let dismissal: TimeInterval = 0.14
}

final class InputProgressIndicator {
    private static let caretHorizontalGap: CGFloat = 8
    private static let indicatorSize = NSSize(width: 38, height: 30)

    private let indicator: ProgressIndicatorView
    private let panel: NSPanel
    private let soundPlayer = InputProgressSoundPlayer()
    private let isSoundEnabled: () -> Bool
    private var dismissalWorkItem: DispatchWorkItem?
    private var resultCompletion: (() -> Void)?
    private var presentationGeneration = 0
    private var reducesMotion = false

    init(isSoundEnabled: @escaping () -> Bool = { true }) {
        self.isSoundEnabled = isSoundEnabled
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
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        completeResultPresentation()

        reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let initialOrigin = panelOrigin(
            for: accessibilityScreenRect,
            indicatorSize: Self.indicatorSize
        ) else {
            return false
        }
        present(at: initialOrigin, operation: operation)
        return true
    }

    func showFallback(
        operation: InputProgressOperation = .optimization
    ) {
        presentationGeneration &+= 1
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        completeResultPresentation()

        let mouseLocation = NSEvent.mouseLocation
        let origin = NSPoint(
            x: mouseLocation.x + Self.caretHorizontalGap,
            y: mouseLocation.y - Self.indicatorSize.height / 2
        )
        present(at: origin, operation: operation)
    }

    private func present(
        at origin: NSPoint,
        operation: InputProgressOperation
    ) {
        reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrameOrigin(
            clampedOrigin(origin, indicatorSize: Self.indicatorSize)
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

    func finish(
        with outcome: OptimizationOutcome,
        operation: InputProgressOperation = .optimization,
        completion: @escaping () -> Void = {}
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
        case (.translation, .unchanged):
            accessibilityDescription = "无需翻译"
        case (.translation, .partial), (.translation, .complete):
            accessibilityDescription = "翻译完成"
        case (.optimization, .unchanged):
            accessibilityDescription = "无需修改"
        case (.optimization, .partial), (.optimization, .complete):
            accessibilityDescription = "优化完成"
        }
        showResult(
            state,
            accessibilityDescription: accessibilityDescription,
            soundCue: .result(for: outcome, operation: operation),
            completion: completion
        )
    }

    func fail() {
        showResult(
            .failed,
            accessibilityDescription: "处理失败",
            soundCue: .failure
        )
    }

    private func showResult(
        _ state: IndicatorVisualState,
        accessibilityDescription: String,
        soundCue: InputProgressSoundCue,
        completion: @escaping () -> Void = {}
    ) {
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        completeResultPresentation()
        resultCompletion = completion

        guard panel.isVisible else {
            hide()
            return
        }

        if isSoundEnabled() {
            soundPlayer.play(soundCue)
        }
        indicator.showResult(state, accessibilityDescription: accessibilityDescription)

        let generation = presentationGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss(ifGenerationMatches: generation)
        }
        dismissalWorkItem = workItem
        let transitionDuration = reducesMotion
            ? IndicatorTiming.resultTransition
            : state.transitionDuration
        let holdDuration = reducesMotion
            ? state.reducedMotionHoldDuration
            : state.holdDuration
        let delay = transitionDuration + holdDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func dismiss(ifGenerationMatches generation: Int) {
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        guard presentationGeneration == generation, panel.isVisible else { return }

        if reducesMotion {
            indicator.stopAnimating()
            panel.orderOut(nil)
            panel.alphaValue = 1
            completeResultPresentation()
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
            self.completeResultPresentation()
        }
    }

    private func completeResultPresentation() {
        let completion = resultCompletion
        resultCompletion = nil
        completion?()
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
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        indicator.stopAnimating()
        panel.orderOut(nil)
        panel.alphaValue = 1
        completeResultPresentation()
    }

    deinit {
        dismissalWorkItem?.cancel()
        completeResultPresentation()
        indicator.stopAnimating()
        panel.orderOut(nil)
    }
}

private final class InputProgressSoundPlayer {
    private var activeSound: NSSound?

    func play(_ cue: InputProgressSoundCue) {
        activeSound?.stop()
        let bundledSound = cue.resourceName.flatMap { resourceName in
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "mp3",
                subdirectory: "Sounds"
            ).flatMap { NSSound(contentsOf: $0, byReference: false) }
        }
        guard let sound = bundledSound ?? NSSound(named: cue.fallbackSoundName) else {
            return
        }
        sound.volume = cue.volume
        activeSound = sound
        sound.play()
    }
}

extension InputProgressSoundCue {
    var resourceName: String? {
        switch self {
        case .completion:
            return "uisfx-minimal-complete"
        case .unchanged, .failure:
            return nil
        }
    }

    var fallbackSoundName: NSSound.Name {
        switch self {
        case .completion:
            return NSSound.Name("Glass")
        case .unchanged:
            return NSSound.Name("Tink")
        case .failure:
            return NSSound.Name("Funk")
        }
    }

    var volume: Float {
        switch self {
        case .completion:
            return 0.24
        case .unchanged:
            return 0.20
        case .failure:
            return 0.24
        }
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
            return InputProgressPalette.completion
        case .unchanged:
            return NSColor(calibratedWhite: 0.82, alpha: 1)
        case .failed:
            return .systemRed
        }
    }

    var holdDuration: TimeInterval {
        switch self {
        case .changed:
            return 0
        case .unchanged:
            return 0.85
        case .failed:
            return 0
        }
    }

    var reducedMotionHoldDuration: TimeInterval {
        switch self {
        case .changed:
            return 0.85
        case .unchanged:
            return holdDuration
        case .failed:
            return 1.0
        }
    }

    var showsCompletionAnimation: Bool {
        self == .changed
    }

    var showsAlertAnimation: Bool {
        self == .failed
    }

    var showsStandaloneAnimation: Bool {
        showsCompletionAnimation || showsAlertAnimation
    }

    var symbolPointSize: CGFloat {
        showsCompletionAnimation ? 12 : 9
    }

    var transitionDuration: TimeInterval {
        switch self {
        case .changed:
            return IndicatorTiming.checkedAnimation
        case .unchanged:
            return IndicatorTiming.resultTransition
        case .failed:
            return IndicatorTiming.alertAnimation
        }
    }
}

private final class ProgressIndicatorView: NSView {
    private static let surfaceColor = NSColor(calibratedWhite: 0.055, alpha: 0.94)
    private static let surfaceBorderColor = NSColor.white.withAlphaComponent(0.14)
    private static let processingColor = NSColor.systemBlue

    private enum Timing {
        static let loadingLoop: CFTimeInterval = 1.0
        static let convergence: CFTimeInterval = 0.20
    }

    private struct LayerSnapshot {
        let position: CGPoint
        let opacity: Float
        let scale: CGFloat
        let dotPositions: [CGPoint]
    }

    private let surfaceLayer = CALayer()
    private let processingBarLayer = CALayer()
    private let loadingDotLayers = [CALayer(), CALayer(), CALayer()]
    private let completionMarkLayer = CALayer()
    private let completionCheckLayer = CAShapeLayer()
    private let completionRaysLayer = CALayer()
    private var completionRayLayers: [CAShapeLayer] = []
    private let alertRootLayer = CALayer()
    private let alertBodyLayer = CAShapeLayer()
    private let alertOutlineLayer = CAShapeLayer()
    private let alertStemLayer = CAShapeLayer()
    private let alertDotLayer = CAShapeLayer()
    private let iconView = NSImageView()
    private var reducesMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        surfaceLayer.frame = CGRect(x: 0, y: 6, width: 30, height: 18)
        surfaceLayer.backgroundColor = Self.surfaceColor.cgColor
        surfaceLayer.cornerRadius = 9
        surfaceLayer.borderWidth = 0.5
        surfaceLayer.borderColor = Self.surfaceBorderColor.cgColor
        layer?.addSublayer(surfaceLayer)

        processingBarLayer.frame = surfaceLayer.frame
        processingBarLayer.masksToBounds = true
        processingBarLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(processingBarLayer)

        let dotColor = Self.processingColor.cgColor
        let sourceXPositions: [CGFloat] = [301.814, 401.814, 501.814]
        let contentScale: CGFloat = 0.06
        for (index, dotLayer) in loadingDotLayers.enumerated() {
            dotLayer.bounds = CGRect(x: 0, y: 0, width: 3.6, height: 3.6)
            dotLayer.position = CGPoint(
                x: processingBarLayer.bounds.midX
                    + (sourceXPositions[index] - 400) * contentScale,
                y: 8.8
            )
            dotLayer.backgroundColor = dotColor
            dotLayer.cornerRadius = 1.8
            processingBarLayer.addSublayer(dotLayer)
        }

        configureCheckedAnimationLayers()
        configureAlertAnimationLayers()

        iconView.frame = NSRect(x: 5, y: 5, width: 20, height: 20)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.alphaValue = 0
        iconView.wantsLayer = true
        addSubview(iconView)
    }

    // Native rendering of https://lottiefiles.com/free-animation/checked-172ggND5kr.
    // The source is a 200x200, 24 FPS, 48-frame Lottie with four vector layers.
    private func configureCheckedAnimationLayers() {
        let completionColor = IndicatorVisualState.changed.color.cgColor

        let completionFrame = CGRect(x: 8, y: 0, width: 30, height: 30)
        completionMarkLayer.frame = completionFrame
        completionMarkLayer.opacity = 0
        layer?.addSublayer(completionMarkLayer)

        let checkPath = CGMutablePath()
        checkPath.move(to: CGPoint(x: 9, y: 15))
        checkPath.addLine(to: CGPoint(x: 13, y: 11))
        checkPath.addLine(to: CGPoint(x: 21, y: 19))
        completionCheckLayer.frame = completionMarkLayer.bounds
        completionCheckLayer.path = checkPath
        completionCheckLayer.fillColor = nil
        completionCheckLayer.strokeColor = completionColor
        completionCheckLayer.lineWidth = 1.7
        completionCheckLayer.lineCap = .round
        completionCheckLayer.lineJoin = .round
        completionCheckLayer.strokeEnd = 1
        completionMarkLayer.addSublayer(completionCheckLayer)

        completionRaysLayer.frame = completionFrame
        completionRaysLayer.opacity = 0
        layer?.addSublayer(completionRaysLayer)

        let center = CGPoint(x: 15, y: 15)
        let innerRadius: CGFloat = 3
        let outerRadius: CGFloat = 11.5
        for index in 0..<10 {
            let radians = CGFloat(index) * 36 * .pi / 180 + .pi / 2
            let direction = CGPoint(x: cos(radians), y: sin(radians))
            let path = CGMutablePath()
            path.move(to: CGPoint(
                x: center.x + direction.x * innerRadius,
                y: center.y + direction.y * innerRadius
            ))
            path.addLine(to: CGPoint(
                x: center.x + direction.x * outerRadius,
                y: center.y + direction.y * outerRadius
            ))

            let rayLayer = CAShapeLayer()
            rayLayer.frame = completionRaysLayer.bounds
            rayLayer.path = path
            rayLayer.fillColor = nil
            rayLayer.strokeColor = completionColor
            rayLayer.lineWidth = 1.45
            rayLayer.lineCap = .round
            rayLayer.strokeStart = 1
            rayLayer.strokeEnd = 1
            completionRaysLayer.addSublayer(rayLayer)
            completionRayLayers.append(rayLayer)
        }
    }

    // Native rendering of https://lottiefiles.com/free-animation/alert-ZX7Oo4AjiA.
    // The source is a 500x500, 29.97 FPS, 80-frame Lottie alert animation.
    private func configureAlertAnimationLayers() {
        let alertFrame = CGRect(x: 8, y: 0, width: 30, height: 30)
        let trianglePath = Self.makeAlertTrianglePath(in: alertFrame.size)

        alertRootLayer.frame = alertFrame
        alertRootLayer.opacity = 0
        layer?.addSublayer(alertRootLayer)

        alertBodyLayer.frame = alertRootLayer.bounds
        alertBodyLayer.path = trianglePath
        alertBodyLayer.fillColor = NSColor(
            calibratedRed: 1,
            green: 0.78394464231,
            blue: 0.125490188599,
            alpha: 1
        ).cgColor
        alertRootLayer.addSublayer(alertBodyLayer)

        alertOutlineLayer.frame = alertRootLayer.bounds
        alertOutlineLayer.path = trianglePath
        alertOutlineLayer.fillColor = nil
        alertOutlineLayer.strokeColor = NSColor.black.cgColor
        alertOutlineLayer.lineWidth = 1.45
        alertOutlineLayer.lineCap = .round
        alertOutlineLayer.lineJoin = .round
        alertRootLayer.addSublayer(alertOutlineLayer)

        let stemPath = CGMutablePath()
        stemPath.move(to: CGPoint(x: 15.55, y: 12.4))
        stemPath.addLine(to: CGPoint(x: 15.55, y: 20.7))
        alertStemLayer.bounds = alertRootLayer.bounds
        alertStemLayer.position = CGPoint(x: 15, y: 12.1)
        alertStemLayer.anchorPoint = CGPoint(x: 0.5, y: 12.1 / 30)
        alertStemLayer.path = stemPath
        alertStemLayer.fillColor = nil
        alertStemLayer.strokeColor = NSColor.black.cgColor
        alertStemLayer.lineWidth = 2.15
        alertStemLayer.lineCap = .round
        alertRootLayer.addSublayer(alertStemLayer)

        alertDotLayer.frame = alertRootLayer.bounds
        alertDotLayer.path = CGPath(
            ellipseIn: CGRect(x: 14.05, y: 7.6, width: 3, height: 3),
            transform: nil
        )
        alertDotLayer.fillColor = NSColor.black.cgColor
        alertRootLayer.addSublayer(alertDotLayer)
    }

    private static func makeAlertTrianglePath(in size: CGSize) -> CGPath {
        let vertices = [
            CGPoint(x: 0, y: 105.676),
            CGPoint(x: -98.937, y: 105.676),
            CGPoint(x: -114.92, y: 77.992),
            CGPoint(x: -65.452, y: -7.69),
            CGPoint(x: -15.983, y: -93.372),
            CGPoint(x: 15.983, y: -93.372),
            CGPoint(x: 65.452, y: -7.69),
            CGPoint(x: 114.921, y: 77.992),
            CGPoint(x: 98.937, y: 105.676)
        ]
        let inTangents = [
            CGPoint.zero,
            CGPoint.zero,
            CGPoint(x: -7.104, y: 12.304),
            CGPoint.zero,
            CGPoint.zero,
            CGPoint(x: -7.104, y: -12.304),
            CGPoint.zero,
            CGPoint.zero,
            CGPoint(x: 14.207, y: 0)
        ]
        let outTangents = [
            CGPoint.zero,
            CGPoint(x: -14.207, y: 0),
            CGPoint.zero,
            CGPoint.zero,
            CGPoint(x: 7.104, y: -12.304),
            CGPoint.zero,
            CGPoint.zero,
            CGPoint(x: 7.104, y: 12.304),
            CGPoint.zero
        ]
        let sourceCenter = CGPoint(x: 0.0005, y: 6.152)
        let scale = min((size.width - 4) / 229.841, (size.height - 4) / 199.048)

        func convert(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: size.width / 2 + (point.x - sourceCenter.x) * scale,
                y: size.height / 2 - (point.y - sourceCenter.y) * scale
            )
        }

        let path = CGMutablePath()
        path.move(to: convert(vertices[0]))
        for index in 1..<vertices.count {
            let previous = vertices[index - 1]
            let current = vertices[index]
            path.addCurve(
                to: convert(current),
                control1: convert(CGPoint(
                    x: previous.x + outTangents[index - 1].x,
                    y: previous.y + outTangents[index - 1].y
                )),
                control2: convert(CGPoint(
                    x: current.x + inTangents[index].x,
                    y: current.y + inTangents[index].y
                ))
            )
        }
        let last = vertices[vertices.count - 1]
        let first = vertices[0]
        path.addCurve(
            to: convert(first),
            control1: convert(CGPoint(
                x: last.x + outTangents[outTangents.count - 1].x,
                y: last.y + outTangents[outTangents.count - 1].y
            )),
            control2: convert(CGPoint(
                x: first.x + inTangents[0].x,
                y: first.y + inTangents[0].y
            ))
        )
        path.closeSubpath()
        return path
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
        surfaceLayer.removeAnimation(forKey: "resultSurfaceFade")
        surfaceLayer.backgroundColor = Self.surfaceColor.cgColor
        surfaceLayer.borderColor = Self.surfaceBorderColor.cgColor
        resetResultAnimationLayers()
        processingBarLayer.opacity = reducesMotion ? 0.82 : 1
        processingBarLayer.transform = CATransform3DIdentity
        processingBarLayer.backgroundColor = NSColor.clear.cgColor
        for dotLayer in loadingDotLayers {
            dotLayer.opacity = 1
            dotLayer.position.y = 8.8
        }
        CATransaction.commit()

        guard !reducesMotion else { return }
        animateAppearance()
        showLoadingProcessing()
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

    // Native rendering of https://lottiefiles.com/free-animation/loading-c5cJgxLvtS.
    // The source is an 800x800, 60 FPS, 60-frame animation with three bouncing dots.
    private func showLoadingProcessing() {
        let sourceTiming = CAMediaTimingFunction(
            controlPoints: 0.583,
            0,
            0.58,
            1
        )
        let sourceMotions: [(frames: [Double], yPositions: [CGFloat])] = [
            ([0, 15, 35, 49, 60], [439.774, 379.774, 479.774, 429.774, 444.5]),
            ([0, 4, 20, 39, 53, 60], [439.774, 439.774, 379.774, 479.774, 429.774, 440]),
            ([0, 8, 25, 44, 57, 60], [439.774, 439.774, 379.774, 479.774, 429.774, 431.5])
        ]

        for (dotLayer, motion) in zip(loadingDotLayers, sourceMotions) {
            let bounce = CAKeyframeAnimation(keyPath: "position.y")
            bounce.values = motion.yPositions.map { sourceY in
                8.8 + (439.774 - sourceY) * 0.06
            }
            bounce.keyTimes = motion.frames.map { NSNumber(value: $0 / 60) }
            bounce.timingFunctions = Array(
                repeating: sourceTiming,
                count: motion.frames.count - 1
            )
            bounce.duration = Timing.loadingLoop
            bounce.repeatCount = .infinity
            bounce.isRemovedOnCompletion = false
            dotLayer.add(bounce, forKey: "loadingBounce")
        }
    }

    func showResult(
        _ state: IndicatorVisualState,
        accessibilityDescription: String
    ) {
        let barSnapshot = snapshotProcessing()
        freezeProcessingLayers(barSnapshot: barSnapshot)

        let configuration = NSImage.SymbolConfiguration(
            pointSize: state.symbolPointSize,
            weight: .semibold
        )
        let usesStandaloneAnimation = state.showsStandaloneAnimation && !reducesMotion
        iconView.image = usesStandaloneAnimation ? nil : NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        iconView.contentTintColor = state.color
        iconView.setAccessibilityLabel(accessibilityDescription)
        setAccessibilityLabel(accessibilityDescription)
        configureResultSurface(for: state)

        if reducesMotion {
            showReducedMotionResult(barSnapshot: barSnapshot)
        } else {
            showConvergingResult(
                state,
                barSnapshot: barSnapshot
            )
        }
    }

    private func configureResultSurface(for state: IndicatorVisualState) {
        surfaceLayer.removeAnimation(forKey: "resultSurfaceFade")
        guard state.showsStandaloneAnimation else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surfaceLayer.backgroundColor = Self.surfaceColor.cgColor
            surfaceLayer.borderColor = Self.surfaceBorderColor.cgColor
            CATransaction.commit()
            return
        }

        let visibleLayer = surfaceLayer.presentation() ?? surfaceLayer
        let backgroundFrom = visibleLayer.backgroundColor ?? Self.surfaceColor.cgColor
        let borderFrom = visibleLayer.borderColor ?? Self.surfaceBorderColor.cgColor
        let clear = NSColor.clear.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.backgroundColor = clear
        surfaceLayer.borderColor = clear
        CATransaction.commit()

        guard !reducesMotion else { return }
        let backgroundFade = CAKeyframeAnimation(keyPath: "backgroundColor")
        backgroundFade.values = [backgroundFrom, backgroundFrom, clear]
        backgroundFade.keyTimes = [0, 0.36, 1]

        let borderFade = CAKeyframeAnimation(keyPath: "borderColor")
        borderFade.values = [borderFrom, borderFrom, clear]
        borderFade.keyTimes = [0, 0.30, 1]

        let surfaceFade = CAAnimationGroup()
        surfaceFade.animations = [backgroundFade, borderFade]
        surfaceFade.duration = IndicatorTiming.resultTransition
        surfaceFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        surfaceLayer.add(surfaceFade, forKey: "resultSurfaceFade")
    }

    private func snapshotProcessing() -> LayerSnapshot {
        let visible = processingBarLayer.presentation() ?? processingBarLayer
        return LayerSnapshot(
            position: visible.position,
            opacity: visible.opacity,
            scale: CGFloat(visible.transform.m11),
            dotPositions: loadingDotLayers.map { dotLayer in
                (dotLayer.presentation() ?? dotLayer).position
            }
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
        for (dotLayer, position) in zip(loadingDotLayers, barSnapshot.dotPositions) {
            dotLayer.removeAllAnimations()
            dotLayer.position = position
        }
        resetResultAnimationLayers()
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        processingBarLayer.opacity = 0
        processingBarLayer.transform = CATransform3DMakeScale(0.16, 0.72, 1)
        iconView.alphaValue = state.showsStandaloneAnimation ? 0 : 1
        iconView.layer?.transform = CATransform3DIdentity
        completionMarkLayer.opacity = state.showsCompletionAnimation ? 1 : 0
        completionRaysLayer.opacity = state.showsCompletionAnimation ? 1 : 0
        alertRootLayer.opacity = state.showsAlertAnimation ? 1 : 0
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

        let convergence = CAAnimationGroup()
        convergence.animations = [barOpacity, barScaleX, barScaleY]
        convergence.duration = Timing.convergence
        convergence.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        processingBarLayer.add(convergence, forKey: "resultConvergence")

        if state.showsCompletionAnimation {
            showCheckedAnimation(duration: state.transitionDuration)
            return
        }

        if state.showsAlertAnimation {
            showAlertAnimation(duration: state.transitionDuration)
            return
        }

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

    private func showCheckedAnimation(duration: CFTimeInterval) {
        let markScale = CAKeyframeAnimation(keyPath: "transform.scale")
        markScale.values = [0, 1, 1]
        markScale.keyTimes = [0, 0.25, 1]

        let markRotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        markRotation.values = [CGFloat.pi / 4, 0, 0]
        markRotation.keyTimes = [0, 0.25, 1]

        let markAppearance = CAAnimationGroup()
        markAppearance.animations = [markScale, markRotation]
        markAppearance.duration = duration
        markAppearance.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.333,
            0,
            0.833,
            0.833
        )
        completionMarkLayer.add(markAppearance, forKey: "checkedMarkAppearance")

        let checkDraw = CAKeyframeAnimation(keyPath: "strokeEnd")
        checkDraw.values = [0, 0, 1, 1]
        checkDraw.keyTimes = [0, 0.25, 0.5, 1]
        checkDraw.duration = duration
        checkDraw.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.333,
            0,
            0,
            1
        )
        completionCheckLayer.add(checkDraw, forKey: "checkedPath")

        for rayLayer in completionRayLayers {
            let rayEnd = CAKeyframeAnimation(keyPath: "strokeEnd")
            rayEnd.values = [0, 0, 1, 1]
            rayEnd.keyTimes = [0, 0.1875, 0.4375, 1]

            let rayStart = CAKeyframeAnimation(keyPath: "strokeStart")
            rayStart.values = [0, 0, 0, 1, 1]
            rayStart.keyTimes = [0, 0.1875, 0.2292, 0.4792, 1]

            let burst = CAAnimationGroup()
            burst.animations = [rayEnd, rayStart]
            burst.duration = duration
            burst.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.333,
                0,
                0,
                1
            )
            rayLayer.add(burst, forKey: "checkedRay")
        }
    }

    private func showAlertAnimation(duration: CFTimeInterval) {
        func time(_ frame: Double) -> NSNumber {
            NSNumber(value: frame / 80)
        }

        func radians(_ degrees: CGFloat) -> CGFloat {
            degrees * .pi / 180
        }

        let sourceTiming = CAMediaTimingFunction(
            controlPoints: 0.333,
            0,
            0.667,
            1
        )

        let appearance = CAKeyframeAnimation(keyPath: "transform.scale")
        appearance.values = [0, 0, 1.182, 0.909, 1.091, 1, 1]
        appearance.keyTimes = [
            time(0), time(0.001), time(6.333), time(11.833),
            time(16.418), time(19.168), time(80)
        ]
        appearance.timingFunctions = Array(repeating: sourceTiming, count: 6)
        appearance.duration = duration
        alertRootLayer.add(appearance, forKey: "alertAppearance")

        let bodyRotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        bodyRotation.values = [
            radians(0), radians(0), radians(5), radians(-3),
            radians(2), radians(-5), radians(0), radians(0)
        ]
        bodyRotation.keyTimes = [
            time(0), time(27), time(29.728), time(32.455),
            time(35.183), time(37.91), time(42), time(80)
        ]
        bodyRotation.timingFunctions = Array(repeating: sourceTiming, count: 7)
        bodyRotation.duration = duration
        alertBodyLayer.add(bodyRotation, forKey: "alertBodyWobble")

        let outlineRotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        outlineRotation.values = [
            radians(0), radians(0), radians(-4), radians(3),
            radians(-2), radians(4), radians(0), radians(0)
        ]
        outlineRotation.keyTimes = [
            time(0), time(48), time(50.25), time(52.5),
            time(54.75), time(57), time(60), time(80)
        ]
        outlineRotation.timingFunctions = Array(repeating: sourceTiming, count: 7)
        outlineRotation.duration = duration
        alertOutlineLayer.add(outlineRotation, forKey: "alertOutlineWobble")

        let stemReveal = CAKeyframeAnimation(keyPath: "transform.scale.y")
        stemReveal.values = [0, 0, 1.092, 0.939, 1, 1]
        stemReveal.keyTimes = [
            time(0), time(18), time(22), time(26), time(30), time(80)
        ]
        stemReveal.timingFunctions = Array(repeating: sourceTiming, count: 5)
        stemReveal.duration = duration
        alertStemLayer.add(stemReveal, forKey: "alertStemReveal")

        let dotReveal = CAKeyframeAnimation(keyPath: "transform.scale.y")
        dotReveal.values = [0, 0, 1.08, 1.02, 1, 1]
        dotReveal.keyTimes = [
            time(0), time(16), time(23.555), time(29.223), time(33), time(80)
        ]
        dotReveal.timingFunctions = Array(repeating: sourceTiming, count: 5)
        dotReveal.duration = duration
        alertDotLayer.add(dotReveal, forKey: "alertDotReveal")

        let dotMovement = CAKeyframeAnimation(keyPath: "transform.translation.y")
        dotMovement.values = [1.7, 1.7, 0, 0]
        dotMovement.keyTimes = [time(0), time(12), time(23), time(80)]
        dotMovement.timingFunctions = Array(repeating: sourceTiming, count: 3)
        dotMovement.duration = duration
        alertDotLayer.add(dotMovement, forKey: "alertDotMovement")
    }

    private func resetCheckedAnimationLayers() {
        completionMarkLayer.removeAllAnimations()
        completionMarkLayer.opacity = 0
        completionMarkLayer.transform = CATransform3DIdentity
        completionCheckLayer.removeAllAnimations()
        completionCheckLayer.strokeEnd = 1
        completionRaysLayer.removeAllAnimations()
        completionRaysLayer.opacity = 0
        for rayLayer in completionRayLayers {
            rayLayer.removeAllAnimations()
            rayLayer.strokeStart = 1
            rayLayer.strokeEnd = 1
        }
    }

    private func resetAlertAnimationLayers() {
        alertRootLayer.removeAllAnimations()
        alertRootLayer.opacity = 0
        alertRootLayer.transform = CATransform3DIdentity
        alertBodyLayer.removeAllAnimations()
        alertBodyLayer.transform = CATransform3DIdentity
        alertOutlineLayer.removeAllAnimations()
        alertOutlineLayer.transform = CATransform3DIdentity
        alertStemLayer.removeAllAnimations()
        alertStemLayer.transform = CATransform3DIdentity
        alertDotLayer.removeAllAnimations()
        alertDotLayer.transform = CATransform3DIdentity
    }

    private func resetResultAnimationLayers() {
        resetCheckedAnimationLayers()
        resetAlertAnimationLayers()
    }

    func stopAnimating() {
        surfaceLayer.removeAllAnimations()
        processingBarLayer.removeAllAnimations()
        for dotLayer in loadingDotLayers {
            dotLayer.removeAllAnimations()
        }
        resetResultAnimationLayers()
        iconView.layer?.removeAllAnimations()
        layer?.removeAllAnimations()
    }
}

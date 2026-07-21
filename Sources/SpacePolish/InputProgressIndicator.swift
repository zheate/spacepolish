import AppKit

final class InputProgressIndicator {
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

        let dots = ProgressDotsView(frame: NSRect(origin: .zero, size: indicatorSize))
        let panel = NSPanel(
            contentRect: dots.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = dots
        panel.setFrameOrigin(origin)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        self.panel = panel
        panel.orderFrontRegardless()
        dots.startAnimating()
    }

    func finish(with outcome: OptimizationOutcome) {
        guard let dots = panel?.contentView as? ProgressDotsView else {
            hide()
            return
        }

        dismissalWorkItem?.cancel()
        dots.showCompletion(color: color(for: outcome))

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        dismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func color(for outcome: OptimizationOutcome) -> NSColor {
        switch outcome {
        case .unchanged:
            return .systemRed
        case .partial:
            return .systemYellow
        case .complete:
            return .systemGreen
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
        (panel?.contentView as? ProgressDotsView)?.stopAnimating()
        panel?.orderOut(nil)
        panel = nil
    }

    deinit {
        hide()
    }
}

private final class ProgressDotsView: NSView {
    private let dots: [CALayer] = (0..<3).map { _ in CALayer() }

    override init(frame frameRect: NSRect) {
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
            dot.opacity = 0.35
            layer?.addSublayer(dot)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAnimating() {
        for (index, dot) in dots.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.35, 1, 0.35, 0.35]
            animation.keyTimes = [0, 0.18, 0.38, 1]
            animation.duration = 0.9
            animation.beginTime = dot.convertTime(CACurrentMediaTime(), from: nil)
                + Double(index) * 0.16
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            dot.add(animation, forKey: "staggeredPulse")
        }
    }

    func stopAnimating() {
        dots.forEach { $0.removeAllAnimations() }
    }

    func showCompletion(color: NSColor) {
        stopAnimating()
        let startTime = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = color.cgColor
            dot.opacity = 1

            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = [0.75, 1.28, 1]
            animation.keyTimes = [0, 0.55, 1]
            animation.duration = 0.3
            animation.beginTime = dot.convertTime(startTime, from: nil)
                + Double(index) * 0.06
            dot.add(animation, forKey: "completionPop")
        }
    }
}

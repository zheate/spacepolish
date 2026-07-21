import AppKit

final class StatusHUD {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func show(_ message: String, isError: Bool = false, duration: TimeInterval = 1.8) {
        dismissWorkItem?.cancel()

        let label = NSTextField(labelWithString: message)
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 54))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 13
        content.layer?.borderWidth = isError ? 1 : 0
        content.layer?.borderColor = isError ? NSColor.systemRed.cgColor : nil
        label.frame = NSRect(x: 18, y: 12, width: 304, height: 30)
        content.addSubview(label)

        let panel = NSPanel(
            contentRect: content.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - panel.frame.width / 2
            let y = screen.visibleFrame.maxY - panel.frame.height - 46
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel?.orderOut(nil)
        self.panel = panel
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.panel === panel { self?.panel = nil }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
}

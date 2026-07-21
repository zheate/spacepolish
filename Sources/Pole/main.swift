import AppKit

final class PoleAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        coordinator?.start()
    }
}

let app = NSApplication.shared
let delegate = PoleAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

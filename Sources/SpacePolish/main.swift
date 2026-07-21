import AppKit

final class SpacePolishAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        coordinator?.start()
    }
}

let app = NSApplication.shared
let delegate = SpacePolishAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

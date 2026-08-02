import AppKit
import Darwin

final class PoleAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        coordinator?.start()
        if Bundle.main.object(forInfoDictionaryKey: "PoleOpenSettingsOnLaunch") as? Bool == true {
            coordinator?.openSettings()
        }
    }
}

let instanceLock: SingleInstanceLock = {
    if let lock = SingleInstanceLock.acquire() {
        return lock
    }
    exit(EXIT_SUCCESS)
}()

let app = NSApplication.shared
if Bundle.main.object(forInfoDictionaryKey: "PoleForceDarkAppearance") as? Bool == true {
    app.appearance = NSAppearance(named: .darkAqua)
}
let delegate = PoleAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
withExtendedLifetime(instanceLock) {
    app.run()
}

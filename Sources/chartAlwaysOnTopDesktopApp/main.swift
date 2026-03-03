import AppKit
import chartAlwaysOnTopDesktop

let app = NSApplication.shared
let delegate = AppCoordinator()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()

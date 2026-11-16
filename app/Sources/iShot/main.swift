import AppKit

// Entry point: a menu-bar-only (accessory) application.
AppLog.start()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

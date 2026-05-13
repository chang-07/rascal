import AppKit

NSWindow.allowsAutomaticWindowTabbing = false

let isHeadless = ProcessInfo.processInfo.environment["FT_HEADLESS_TESTING"] == "1"

// Stamp the launch start so AppDelegate can report cold-launch time.
LaunchMetrics.shared.processStart = ProcessInfo.processInfo.systemUptime

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Headless test mode: .accessory so we have no Dock icon and never steal focus.
app.setActivationPolicy(isHeadless ? .accessory : .regular)
app.run()

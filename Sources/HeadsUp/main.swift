import AppKit
import HeadsUpKit

// Single-instance lock: if another Heads Up is already running, activate it
// and exit instead of spawning a second tray/scheduler/window set.
let bundleID = Bundle.main.bundleIdentifier ?? "com.cedoreholdings.headsup"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if let other = others.first {
    other.activate()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

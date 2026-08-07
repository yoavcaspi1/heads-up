import AppKit
import SwiftUI

/// Owns the single Settings window. Same hide-on-close pattern as
/// MainWindowController (Task 12): closing hides rather than destroys, so
/// the model's state (pending input, loaded calendars) survives across
/// show/hide cycles. Deliberately does NOT set `.canJoinAllSpaces` collection
/// behaviour: Settings is a single-Space utility window, unlike the main
/// calendar window.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let model: SettingsModel
    private let makeContent: () -> NSView

    init(settingsStore: SettingsStore, credentials: GoogleCredentialsStore,
         registry: GoogleAccountsRegistry, calendarClient: GoogleCalendarClient,
         scheduler: Scheduler, onTestAlert: @escaping () -> Void) {
        // AppDelegate builds every window controller on the main thread
        // during applicationDidFinishLaunching. assumeIsolated documents
        // that existing guarantee to the type checker rather than spreading
        // @MainActor upward through TrayController/CalendarListView's plain
        // () -> Void closure types, matching how the rest of this app is
        // main-thread-confined by convention, not by formal actor isolation.
        let model = MainActor.assumeIsolated {
            SettingsModel(
                settingsStore: settingsStore, credentials: credentials, registry: registry,
                calendarClient: calendarClient, scheduler: scheduler, onTestAlert: onTestAlert)
        }
        self.model = model
        self.makeContent = { NSHostingView(rootView: SettingsView(model: model)) }
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Heads Up Settings"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = makeContent()
            w.center()
            window = w
        }
        MainActor.assumeIsolated { model.onWindowShow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing hides; the window is recreated cheaply but state lives in the model.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

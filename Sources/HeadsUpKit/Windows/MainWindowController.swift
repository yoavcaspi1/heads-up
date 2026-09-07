import AppKit
import SwiftUI

/// Owns the single main window: calendar list, toggled from the tray icon.
/// Closing hides rather than destroys, so state (scroll position, model) is
/// cheap to preserve across show/hide cycles.
final class MainWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let model: CalendarListModel
    private let makeContent: () -> NSView

    init(scheduler: Scheduler, registry: GoogleAccountsRegistry,
         credentials: GoogleCredentialsStore,
         onOpenSettings: @escaping () -> Void,
         onOpenEvent: @escaping (CalendarEvent) -> Void) {
        let model = CalendarListModel(scheduler: scheduler, registry: registry, credentials: credentials)
        self.model = model
        self.makeContent = {
            NSHostingView(rootView: CalendarListView(onOpenEvent: onOpenEvent,
                                                     model: model,
                                                     onOpenSettings: onOpenSettings))
        }
        super.init()
    }

    /// Opens scrolled so `event` sits at the top of the list; with nil the
    /// list opens at today (or the nearest upcoming day). The request is
    /// filed before the content view exists on first open, so the view's
    /// onAppear can honour it; later opens reach the view through onChange.
    func toggle(focusing event: CalendarEvent? = nil) {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        model.requestScroll(to: event)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Heads Up"
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.delegate = self
            w.contentView = makeContent()
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing hides; the window is recreated cheaply but state lives in the model.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

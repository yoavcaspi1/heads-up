import AppKit
import SwiftUI

/// Owns the calendar popover: the day-by-day list hangs off the menu-bar
/// item with the system arrow pointing back at it, so it reads as part of
/// the tray rather than a free-floating window. Transient, like any
/// menu-bar popover: clicking anywhere outside closes it. The content view
/// and its model live for the app's lifetime; only the popover shell is
/// shown and hidden, so list state is cheap to keep across opens.
final class CalendarPopoverController: NSObject, NSPopoverDelegate {
    private let model: CalendarListModel
    private let contentController: NSViewController
    private var popover: NSPopover?
    /// When the popover is transient, a click on the status item first
    /// closes it (mouse-down outside) and only then fires the button
    /// action (mouse-up). Without this the toggle would see "not shown"
    /// and reopen it immediately, making the item impossible to close.
    private var lastClosedAt: Date = .distantPast
    private static let reopenGuard: TimeInterval = 0.4

    init(scheduler: Scheduler, registry: GoogleAccountsRegistry,
         credentials: GoogleCredentialsStore,
         onOpenSettings: @escaping () -> Void,
         onOpenEvent: @escaping (CalendarEvent) -> Void) {
        let model = CalendarListModel(scheduler: scheduler, registry: registry, credentials: credentials)
        self.model = model
        self.contentController = NSHostingController(
            rootView: CalendarListView(onOpenEvent: onOpenEvent, model: model, onOpenSettings: onOpenSettings))
        super.init()
    }

    /// Show anchored under `button` (the status item), scrolled to today;
    /// hide if already shown. Nil anchor (menu bar calendar disabled) is a
    /// no-op: a popover has nothing to hang off.
    func toggle(anchoredTo button: NSStatusBarButton?) {
        if let popover, popover.isShown {
            FileDiag.log("calendar: toggle -> close")
            popover.performClose(nil)
            return
        }
        if Date().timeIntervalSince(lastClosedAt) < Self.reopenGuard {
            FileDiag.log("calendar: toggle within reopen guard, ignored")
            return
        }
        guard let button else {
            FileDiag.log("calendar: toggle with no status item to anchor to")
            return
        }
        FileDiag.log("calendar: toggle -> show")
        model.requestScrollToToday()
        let popover = self.popover ?? makePopover()
        // A popover inherits its appearance from the positioning view's
        // window, i.e. the menu bar, which follows the system, not the
        // app's own light/dark setting. Re-sync on every show so a settings
        // change is picked up too.
        popover.appearance = NSApp.appearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Accessory apps are not active when the tray is clicked; without
        // activation the popover gets no key events (Escape, tab focus).
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.contentViewController = contentController
        popover.contentSize = CalendarListView.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        lastClosedAt = Date()
        FileDiag.log("calendar: popover closed")
    }

    func popoverDidShow(_ notification: Notification) {
        FileDiag.log("calendar: popover shown")
        // The pre-show request scrolls while the popover is still animating
        // to size and can land a row short; ask again now that layout is
        // final.
        model.requestScrollToToday()
    }

    func popoverWillShow(_ notification: Notification) {
        paintFrame()
    }

    /// The popover chrome, arrow included, is a system material that does
    /// not match the app canvas, so the list would sit in a mismatched
    /// bubble with an off-colour arrow. Slip a canvas-coloured view behind
    /// the content inside the popover's frame view: AppKit clips that view
    /// to the bubble-plus-arrow shape, so the arrow takes the canvas colour
    /// too. Idempotent; the frame view persists across shows.
    private func paintFrame() {
        guard let frameView = contentController.view.window?.contentView?.superview else { return }
        if frameView.subviews.contains(where: { $0 is PopoverBackdropView }) { return }
        let backdrop = PopoverBackdropView(frame: frameView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        frameView.addSubview(backdrop, positioned: .below, relativeTo: frameView.subviews.first)
    }
}

/// Layer-backed fill in the design-system canvas colour. Resolves the
/// dynamic colour in updateLayer so it follows light/dark switches.
private final class PopoverBackdropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = YCDesignSystemNSColor.canvas.cgColor
    }
}

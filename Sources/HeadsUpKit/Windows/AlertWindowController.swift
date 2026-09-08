import AppKit
import SwiftUI

/// Borderless panels refuse key status by default; without key status the
/// alert's buttons and Escape handling never receive events.
final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One full-screen always-on-top window per display, covering the menu bar,
/// following the user across Spaces and over full-screen apps.
final class AlertWindowController {
    private let settingsStore: SettingsStore
    private let onSnooze: (CalendarEvent, Int) -> Void
    /// Fired when the USER dismisses an alert (Dismiss button, Join, Escape),
    /// as opposed to programmatic dismissals and the snooze path. The app
    /// suppresses every remaining alert for that event.
    private let onUserDismissed: (CalendarEvent) -> Void

    private var windows: [AlertPanel] = []
    private(set) var currentEvent: CalendarEvent?
    private var keyMonitor: Any?
    /// Called after every dismiss, whatever triggered it (Escape, buttons,
    /// snooze). Lets the app undo alert-scoped arrangements, e.g. restoring
    /// the Settings window level after a test-alert preview.
    var onDismissed: (() -> Void)?
    /// Monotonic show() counter. Pending retry/diagnostic closures capture
    /// the generation they were scheduled for and no-op when a dismiss or a
    /// newer show has moved things on, so a stale timer never acts on (or
    /// logs against) a newer alert's windows.
    private var showGeneration = 0
    /// True once the app has been active at any point since the current
    /// show(). Distinguishes "the OS refused activation" (retry) from "the
    /// user deliberately switched away after we activated" (leave them be).
    private var becameActiveSinceShow = false
    private var becameActiveObserver: Any?
    /// The AlertBackground mode `windows` were built with. `isOpaque` is set
    /// once at panel creation and never re-evaluated on a content swap, so
    /// this lets `show()` detect a mode change (solid <-> blur) while an
    /// alert is already up and rebuild the panels instead of leaving them
    /// stale (opaque under blur, or vice versa).
    private var windowsAlertBackground: AppSettings.AlertBackground?
    /// Live-geometry observers, alive only while an alert is on screen.
    private var screenParametersObserver: Any?
    private var screensWokeObserver: Any?

    init(settingsStore: SettingsStore,
         onSnooze: @escaping (CalendarEvent, Int) -> Void,
         onUserDismissed: @escaping (CalendarEvent) -> Void) {
        self.settingsStore = settingsStore
        self.onSnooze = onSnooze
        self.onUserDismissed = onUserDismissed
    }

    /// Dismissal initiated by the user: tell the app to suppress every
    /// remaining alert for this event, then close. Test previews are
    /// closed without suppression bookkeeping.
    func dismissByUser() {
        if let event = currentEvent, !event.isTest {
            FileDiag.log("alert (\(Self.tag(event))): user dismissed, suppressing further alerts")
            onUserDismissed(event)
        }
        dismiss()
    }

    var isOpen: Bool { !windows.isEmpty }

    /// Re-applies the current appearance settings to an alert that is already
    /// on screen, so Settings changes (blur tint intensity, solid vs blur)
    /// take effect live instead of only on the next alert. show() itself
    /// decides between a content swap and a full panel rebuild.
    func refreshAppearance() {
        guard isOpen, let event = currentEvent else { return }
        show(event)
    }

    /// Diagnostic seam: is the primary alert panel actually key. If not, no
    /// window is receiving keyboard events (Escape, button clicks) at all.
    var isKeyWindow: Bool { windows.first?.isKeyWindow ?? false }

    /// Short, content-free identity for diagnostic lines: distinguishes real
    /// alerts from test previews without logging meeting titles.
    private static func tag(_ event: CalendarEvent) -> String {
        event.isTest ? "test" : "event \(event.id.prefix(8))"
    }

    func show(_ event: CalendarEvent) {
        currentEvent = event
        let settings = settingsStore.settings
        observeScreenChanges()

        // Alert already up in the same background mode, and the existing
        // panels still match the current display layout: swap content in
        // place instead of stacking windows. The replacement alert still
        // gets the full activation, retry and diagnostics pass below: a
        // silent focus refusal on the second event must be recovered and
        // logged like any other.
        //
        // Otherwise rebuild. Two things force that: a background mode change
        // (isOpaque is fixed at panel creation, so a content-only swap would
        // leave a blur-mode alert opaque, or a solid-mode alert transparent),
        // and a display count change (panels are one-per-screen, so the
        // mapping itself is stale and cannot be fixed by resizing).
        if isOpen, windowsAlertBackground == settings.alertBackground, applyScreenFrames() {
            for window in windows { window.contentView = makeContentView(event) }
        } else {
            closeWindows()
            buildWindows(for: event, settings: settings)
        }

        activateAndVerify(tag: Self.tag(event))
        // The panels may have been built from geometry the window server was
        // still settling (the wake-from-sleep case), so take a second look
        // shortly after showing.
        refitWindowsSoon()
    }

    private func buildWindows(for event: CalendarEvent, settings: AppSettings) {
        for screen in NSScreen.screens {
            let panel = AlertPanel(contentRect: screen.frame,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false, screen: screen)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = settings.alertBackground == .solid
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.setFrame(screen.frame, display: true)
            panel.contentView = makeContentView(event)
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        windowsAlertBackground = settings.alertBackground
    }

    // MARK: - Screen geometry

    /// Screen geometry is only sampled when the panels are built, so anything
    /// that moves it afterwards leaves the alert covering a stale rect: the
    /// desktop stays visible beside a part-screen overlay. Wake from sleep is
    /// the common trigger, since the window server can report transitional
    /// geometry for a moment after the display comes back, and a resolution
    /// or display change while an alert is up does the same.
    private func observeScreenChanges() {
        if screenParametersObserver == nil {
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                self?.refitWindowsSoon()
            }
        }
        if screensWokeObserver == nil {
            screensWokeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil, queue: .main) { [weak self] _ in
                self?.refitWindowsSoon()
            }
        }
    }

    /// Re-fit now and once more shortly after: geometry settles
    /// asynchronously, so the notification itself can arrive while the
    /// window server still reports the old or a transitional frame.
    private func refitWindowsSoon() {
        refitWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refitWindows()
        }
    }

    /// Re-applies the live screen frames, rebuilding the panels when the
    /// display count no longer matches. Safe to call at any time: a no-op
    /// when nothing is open or every panel already fits its screen.
    private func refitWindows() {
        guard isOpen, let event = currentEvent else { return }
        guard !applyScreenFrames() else { return }
        FileDiag.log("alert (\(Self.tag(event))): display count changed, rebuilding alert windows")
        closeWindows()
        buildWindows(for: event, settings: settingsStore.settings)
        // The rebuild destroyed the key window; restore it without a fresh
        // activation pass, which would yank focus back if the user had
        // deliberately switched away.
        windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Resizes each open panel to its screen's current frame. Returns false
    /// when the panel-per-screen mapping itself is stale (a display was
    /// added or removed), which resizing cannot fix.
    private func applyScreenFrames() -> Bool {
        let screens = NSScreen.screens
        guard screens.count == windows.count else { return false }
        for (panel, screen) in zip(windows, screens) where panel.frame != screen.frame {
            FileDiag.log("alert: screen geometry changed, refitting alert window")
            panel.setFrame(screen.frame, display: true)
        }
        return true
    }

    /// Activation, Escape monitoring, one refusal-scoped retry, and the
    /// focus diagnostic. Runs for fresh windows AND content swaps.
    ///
    /// .nonactivatingPanel keeps window creation from stealing focus, but
    /// that means the app itself may still be inactive here: with the app
    /// inactive, keyDown (including Escape) routes to whichever app WAS
    /// active, and this window's local NSEvent monitor never sees it.
    /// Explicit activation on show is the intended behaviour. Cooperative
    /// activation on modern macOS can still refuse to bring a background
    /// app forward, so after a second we retry once, but ONLY when the app
    /// never became active at all: if the user was brought to the alert and
    /// then deliberately switched away, yanking focus back would fight
    /// their explicit choice.
    private func activateAndVerify(tag: String) {
        showGeneration += 1
        let generation = showGeneration
        becameActiveSinceShow = NSApp.isActive
        if becameActiveObserver == nil {
            becameActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                self?.becameActiveSinceShow = true
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.keyCode == 53 {   // Escape
                    FileDiag.log("alert: escape received, dismissing")
                    self?.dismissByUser()
                    return nil
                }
                return e
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isOpen, self.showGeneration == generation else { return }
            if !NSApp.isActive {
                if self.becameActiveSinceShow {
                    FileDiag.log("alert (\(tag)): user switched away, not re-activating")
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    self.windows.first?.makeKeyAndOrderFront(nil)
                }
            } else if !self.isKeyWindow {
                self.windows.first?.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.isOpen, self.showGeneration == generation else { return }
                FileDiag.log("alert shown (\(tag)): active=\(NSApp.isActive) key=\(self.isKeyWindow)")
            }
        }
    }

    func dismiss() {
        if let event = currentEvent { FileDiag.log("alert (\(Self.tag(event))): dismissed") }
        currentEvent = nil
        showGeneration += 1   // invalidate any pending retry/diagnostic closure
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        if let observer = becameActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            becameActiveObserver = nil
        }
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParametersObserver = nil
        }
        if let observer = screensWokeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            screensWokeObserver = nil
        }
        closeWindows()
        onDismissed?()
    }

    private func closeWindows() {
        let toClose = windows
        windows = []
        windowsAlertBackground = nil
        for w in toClose { w.close() }
    }

    private func makeContentView(_ event: CalendarEvent) -> NSView {
        let settings = settingsStore.settings
        let root = AlertView(
            event: event,
            snoozeDurations: settings.snoozeDurations,
            titleFontChoice: settings.alertTitleFont,
            onJoin: { [weak self] in
                if let url = event.meetingUrl.flatMap(URL.init(string:)) {
                    NSWorkspace.shared.open(url)
                }
                // Joining means the reminder did its job; nothing further
                // should fire for this event.
                self?.dismissByUser()
            },
            onDismiss: { [weak self] in self?.dismissByUser() },
            onSnooze: { [weak self] minutes in
                self?.onSnooze(event, minutes)
                self?.dismiss()
            })

        let container = NSView()
        if settings.alertBackground == .blur {
            let effect = NSVisualEffectView()
            effect.material = .fullScreenUI
            effect.blendingMode = .behindWindow
            effect.state = .active
            // The full-screen material at full strength reads as near-solid;
            // at half opacity the desktop behind shows through the frosting.
            effect.alphaValue = 0.5
            effect.autoresizingMask = [.width, .height]
            container.addSubview(effect)
            effect.frame = container.bounds
        } else {
            let solid = NSHostingView(rootView: YCDesignSystem.Colors.canvas.ignoresSafeArea())
            solid.autoresizingMask = [.width, .height]
            container.addSubview(solid)
            solid.frame = container.bounds
        }
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        hosting.frame = container.bounds
        return container
    }
}

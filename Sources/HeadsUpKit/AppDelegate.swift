import AppKit
import CoreText
import Sparkle

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsStore: SettingsStore!
    private var credentials: GoogleCredentialsStore!
    private var oauth: GoogleOAuth!
    private var registry: GoogleAccountsRegistry!
    private var calendarClient: GoogleCalendarClient!
    private var scheduler: Scheduler!
    private var alerts: AlertWindowController!
    private var tray: TrayController!
    private var mainWindow: MainWindowController!
    private var settingsWindow: SettingsWindowController!
    private var setupWizard: SetupWizardWindowController!
    // nil when running as a bare executable (swift run): Sparkle needs a
    // real bundle with SUFeedURL to start, and dev runs have neither.
    private var updaterController: SPUStandardUpdaterController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        // Accessory apps get no default main menu, and without one the standard
        // Cmd+X/C/V/A key equivalents never reach text fields (the Settings
        // credential inputs were un-pasteable). The menu is invisible for an
        // accessory app but its key equivalents still drive the responder chain.
        buildMainMenu()

        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("HeadsUp")
        settingsStore = SettingsStore(directory: supportDir)
        let secrets = KeychainSecretStore(service: KeychainSecretStore.defaultService)
        // The group's domain moved to eloryo.com, so the Keychain service was
        // renamed with it. Adopt anything an earlier version left under the
        // old name before the first read. Silent and idempotent: once there
        // is nothing left to move this costs a single attribute query, which
        // reads attributes only and so never raises an access prompt.
        //
        // Note this relabels items, it does not re-file them: an item keeps
        // the access-control list it was created with. 1.2.0 also renamed the
        // bundle identifier, which is part of a self-signed app's designated
        // requirement, so the first launch after updating asks the user to
        // confirm access to each item it already owns (see the README).
        secrets.migrateItems(fromService: KeychainSecretStore.legacyService)
        credentials = GoogleCredentialsStore(secrets: secrets)
        oauth = GoogleOAuth(credentials: credentials, secrets: secrets)
        registry = GoogleAccountsRegistry(directory: supportDir, oauth: oauth)
        calendarClient = GoogleCalendarClient(registry: registry, settingsStore: settingsStore)

        alerts = AlertWindowController(
            settingsStore: settingsStore,
            onSnooze: { [weak self] event, minutes in
                self?.scheduler.snooze(event: event, minutes: minutes)
            },
            onUserDismissed: { [weak self] event in
                self?.scheduler.markDismissed(event: event)
            })
        scheduler = Scheduler(calendarClient: calendarClient, settingsStore: settingsStore,
                              registry: registry, credentials: credentials,
                              showAlert: { [weak self] event in
                                  DispatchQueue.main.async { self?.alerts.show(event) }
                              })
        tray = TrayController(scheduler: scheduler, settingsStore: settingsStore,
                              onToggleCalendar: { [weak self] in self?.toggleMainWindow() },
                              onOpenSettings: { [weak self] in self?.openSettings() })
        applyAppearance()
        tray.applySetting()

        if Bundle.main.bundleIdentifier != nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        tray.onCheckForUpdates = { [weak self] in
            self?.updaterController?.checkForUpdates(nil)
        }

        // The first keychain read happens on a background queue: a pending
        // keychain permission prompt (common right after a re-signed build)
        // must never wedge the launch. The tray, menu bar and quit handling
        // are already alive at this point; everything that depends on the
        // credentials finishes initialising once the read returns.
        credentials.preload { [weak self] in
            self?.finishLaunching()
        }
    }

    private func finishLaunching() {
        mainWindow = MainWindowController(
            scheduler: scheduler, registry: registry, credentials: credentials,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenEvent: { [weak self] event in self?.openEvent(event) })
        settingsWindow = SettingsWindowController(
            settingsStore: settingsStore, credentials: credentials, registry: registry,
            calendarClient: calendarClient, scheduler: scheduler,
            onTestAlert: { [weak self] in self?.showTestAlert() })
        // A test-alert preview raises the Settings window above the alert so
        // the appearance controls stay reachable; undo that on any dismiss.
        alerts.onDismissed = { [weak self] in
            self?.settingsWindow.window?.level = .normal
        }

        setupWizard = SetupWizardWindowController(credentials: credentials, registry: registry)
        tray.onOpenSetupGuide = { [weak self] in self?.setupWizard?.show() }
        if SetupWizardModel.shouldAutoShow(credentialsConfigured: credentials.isConfigured)
            || ProcessInfo.processInfo.arguments.contains("--setup-wizard") {
            setupWizard.show()
        }

        lastAlertAppearance = appearanceSignature(settingsStore.settings)
        settingsStore.addObserver { [weak self] settings in
            guard let self else { return }
            self.scheduler.rescheduleNow()
            self.tray.applySetting()
            self.applyAppearance()
            // Refresh a visible alert only when a field it renders actually
            // changed; unrelated settings writes must not rebuild the
            // alert's view tree (that closes open menus and resets timers).
            let signature = self.appearanceSignature(settings)
            if signature != self.lastAlertAppearance {
                self.lastAlertAppearance = signature
                self.alerts.refreshAppearance()
            }
        }

        // Debug seam: posting this distributed notification fires the test
        // alert on a RUNNING instance, reproducing the scheduled-alert path
        // (app in the background, another app frontmost). Registered ONLY
        // when the instance was launched with --debug-seam: distributed
        // notifications are postable by any local process, and a production
        // instance must not expose a trigger that can steal focus or swap a
        // real alert's content on demand.
        if ProcessInfo.processInfo.arguments.contains("--debug-seam") {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.yoavcaspi.headsup.debug.test-alert"),
                object: nil, queue: .main) { [weak self] notification in
                // The notification object may carry a custom title so layout
                // issues can be reproduced with the exact offending text.
                self?.showTestAlert(title: notification.object as? String)
            }
        }

        scheduler.start()

        if ProcessInfo.processInfo.arguments.contains("--show-main") {
            // Debug-only entry point: opens the main window headlessly for
            // screenshot-based verification (no tray click available in CI).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.toggleMainWindow()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--test-alert") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.showTestAlert()
                // Diagnostic: confirms the app actually took focus and the
                // primary alert panel is key, i.e. Escape and the buttons
                // are wired to receive events, not silently swallowed by
                // whichever app was active before the alert appeared.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSLog("test-alert diag: active=%@ key=%@",
                          NSApp.isActive ? "true" : "false",
                          self.alerts.isKeyWindow ? "true" : "false")
                }
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        scheduler?.stop()
        tray?.destroy()
    }

    /// Cmd+Q lands here via the main menu. A full-screen alert force-activates
    /// this app, so a reflexive Cmd+Q aimed at "make it go away" would kill
    /// the whole alerting app; confirm instead of terminating silently.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let alerts, alerts.isOpen, alerts.currentEvent?.isTest == false else {
            return .terminateNow
        }
        let confirm = NSAlert()
        confirm.messageText = "A meeting alert is on screen"
        confirm.informativeText = "Quit Heads Up entirely, or just dismiss the alert? Quitting stops all future meeting alerts until you relaunch."
        confirm.addButton(withTitle: "Dismiss Alert")
        confirm.addButton(withTitle: "Quit Heads Up")
        confirm.addButton(withTitle: "Cancel")
        switch confirm.runModal() {
        case .alertFirstButtonReturn:
            alerts.dismissByUser()
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// The settings fields the on-screen alert actually renders.
    private var lastAlertAppearance: String?
    private func appearanceSignature(_ settings: AppSettings) -> String {
        "\(settings.alertBackground.rawValue)-\(settings.alertBlurIntensity)-\(settings.alertTitleFont.rawValue)"
    }

    private func applyAppearance() {
        switch settingsStore.settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Minimal main menu so standard edit key equivalents work in text fields.
    /// Selectors dispatch through the responder chain to the field editor.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Heads Up",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func toggleMainWindow() {
        // nil only in the short window before the background credentials
        // preload finishes launching the window controllers.
        mainWindow?.toggle()
    }

    func openSettings() {
        settingsWindow?.show()
    }

    /// Opens a clicked calendar event in the app the settings choose.
    /// Google Calendar uses the event's own web page; Apple Calendar has no
    /// per-event URL for unsynced Google events, so it opens Calendar.app
    /// focused on the event's start time via the calshow scheme.
    func openEvent(_ event: CalendarEvent) {
        switch settingsStore.settings.eventOpenTarget {
        case .googleWeb:
            guard let link = event.htmlLink, let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        case .appleCalendar:
            let interval = event.start.timeIntervalSinceReferenceDate
            guard let url = URL(string: "calshow:\(interval)") else { return }
            NSWorkspace.shared.open(url)
        case .notionCalendar:
            guard let url = NotionCalendarLink.showEventURL(for: event) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Settings "Test alert" and any debug path use this.
    func showTestAlert(title: String? = nil) {
        // Never replace a REAL alert with the preview: a real event's lead
        // time is already marked fired and would not re-show.
        if alerts.isOpen, alerts.currentEvent?.isTest == false {
            FileDiag.log("test alert suppressed: real alert on screen")
            return
        }
        var event = CalendarEvent(
            id: "test", title: title ?? "Test alert",
            start: Date().addingTimeInterval(5 * 60), end: Date().addingTimeInterval(35 * 60),
            allDay: false, location: "Heads Up preview",
            meetingUrl: "https://meet.google.com/test", meetingProvider: "meet",
            accountEmail: nil, calendarName: nil, htmlLink: nil)
        event.isTest = true
        alerts.show(event)
        // Keep the Settings window (the only appearance controls) usable
        // above the preview so solid/blur and tint changes preview live.
        if let window = settingsWindow?.window, window.isVisible {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.orderFront(nil)
        }
    }
}

/// Registers the bundled Syne / DM Sans / DM Mono fonts with the font
/// manager so YCDesignSystem.Typography resolves them. Safe to call when
/// fonts are missing: the design system falls back to the system font.
public func registerBundledFonts() {
    guard let fontsURL = Bundle.module.url(forResource: "Resources/Fonts", withExtension: nil)
        ?? Bundle.module.url(forResource: "Fonts", withExtension: nil) else { return }
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: fontsURL, includingPropertiesForKeys: nil)) ?? []
    for url in urls where url.pathExtension.lowercased() == "ttf" {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

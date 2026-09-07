import AppKit

/// NSStatusItem wiring around TrayModel. Left-click toggles the calendar
/// window, right-click pops Settings/Quit. Never assign a persistent
/// statusItem.menu: that would swallow left-clicks too.
final class TrayController: NSObject {
    private let scheduler: Scheduler
    private let settingsStore: SettingsStore
    /// Called with the meeting the menu bar title currently shows (nil in
    /// the icon-only state) so the calendar can open scrolled to it.
    private let onToggleCalendar: (CalendarEvent?) -> Void
    private let onOpenSettings: () -> Void

    var onOpenSetupGuide: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var tickTimer: Timer?
    private var eventsObserver: UUID?
    private var lastActive: Bool?

    private static let activeColor = YCDesignSystemNSColor.harbor
    private static let doneColor = YCDesignSystemNSColor.sage

    init(scheduler: Scheduler, settingsStore: SettingsStore,
         onToggleCalendar: @escaping (CalendarEvent?) -> Void, onOpenSettings: @escaping () -> Void) {
        self.scheduler = scheduler
        self.settingsStore = settingsStore
        self.onToggleCalendar = onToggleCalendar
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func applySetting() {
        if settingsStore.settings.menuBarCalendarEnabled {
            create()
        } else {
            destroy()
        }
    }

    private func create() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        tick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        eventsObserver = scheduler.onEventsChanged { [weak self] in self?.tick() }
    }

    func destroy() {
        tickTimer?.invalidate(); tickTimer = nil
        if let id = eventsObserver { scheduler.removeEventsChangedObserver(id) }
        eventsObserver = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        lastActive = nil
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            // Same source as the title (trayEvents, so a skipped meeting is
            // never the focus): whatever the bar names is what opens on top.
            onToggleCalendar(TrayModel.focusEvent(scheduler.trayEvents, now: Date(), calendar: .current))
        }
    }

    private static let menuTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        // Skip meeting: today's remaining meetings, checkmarked when already
        // skipped. Skipping hides the meeting from the menu bar title and
        // suppresses its alerts; clicking a checkmarked one un-skips it.
        let skippable = TrayModel.skippableEvents(scheduler.cachedEvents, now: Date(), calendar: .current)
        let skipParent = NSMenuItem(title: "Skip Meeting", action: nil, keyEquivalent: "")
        let skipMenu = NSMenu()
        if skippable.isEmpty {
            let none = NSMenuItem(title: "No more meetings today", action: nil, keyEquivalent: "")
            none.isEnabled = false
            skipMenu.addItem(none)
        } else {
            for event in skippable {
                let title = "\(Self.menuTimeFormatter.string(from: event.start))  \(event.title)"
                let entry = NSMenuItem(title: title, action: #selector(toggleSkip(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = event.schedulerKey
                entry.state = scheduler.isSkipped(event) ? .on : .off
                skipMenu.addItem(entry)
            }
        }
        skipParent.submenu = skipMenu
        menu.addItem(skipParent)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let guide = NSMenuItem(title: "Setup Guide…", action: #selector(openSetupGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let update = NSMenuItem(title: "Check for Updates…",
                                action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Heads Up", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleSkip(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let event = scheduler.cachedEvents.first(where: { $0.schedulerKey == key }) else { return }
        if scheduler.isSkipped(event) {
            scheduler.unskip(event: event)
        } else {
            scheduler.skip(event: event)
        }
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func openSetupGuide() {
        onOpenSetupGuide?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    private func tick() {
        guard let button = statusItem?.button else { return }
        // trayEvents, not cachedEvents: skipped meetings never surface in
        // the menu bar title.
        let state = TrayModel.state(events: scheduler.trayEvents, now: Date(), calendar: .current)
        button.title = state.title.isEmpty ? "" : " \(state.title)"
        button.toolTip = state.tooltip
        if lastActive != state.meetingsRemainToday {
            lastActive = state.meetingsRemainToday
            let color = state.meetingsRemainToday ? Self.activeColor : Self.doneColor
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            let image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Heads Up")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
            button.imagePosition = .imageLeading
        }
    }
}

/// Tray tint values, named for back-porting into the design tokens if they
/// ever need to exist as first-class tokens. Harbor = accent, sage = success.
enum YCDesignSystemNSColor {
    static let harbor = NSColor(red: 0x3E / 255.0, green: 0x6E / 255.0, blue: 0x93 / 255.0, alpha: 1)
    static let sage = NSColor(red: 0x3F / 255.0, green: 0x6A / 255.0, blue: 0x4E / 255.0, alpha: 1)
}

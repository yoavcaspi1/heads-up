import AppKit

/// NSStatusItem wiring around TrayModel. Left-click toggles the calendar
/// window, right-click pops Settings/Quit. Never assign a persistent
/// statusItem.menu: that would swallow left-clicks too.
final class TrayController: NSObject {
    private let scheduler: Scheduler
    private let settingsStore: SettingsStore
    private let onToggleCalendar: () -> Void
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
         onToggleCalendar: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.scheduler = scheduler
        self.settingsStore = settingsStore
        self.onToggleCalendar = onToggleCalendar
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    /// Anchor for the calendar popover; nil while the menu bar item is off.
    var statusButton: NSStatusBarButton? { statusItem?.button }

    func applySetting() {
        if settingsStore.settings.menuBarCalendarEnabled {
            create()
            // Redraw now: an already-created item would otherwise keep a
            // stale title until the next 30 s tick after a settings change.
            tick()
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
            onToggleCalendar()
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
        let now = Date()
        let skippable = TrayModel.skippableEvents(scheduler.cachedEvents, now: now, calendar: .current)
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

        // Snooze meeting: hide a not-yet-started meeting from the menu bar
        // title until start minus the chosen lead. Alerts still fire and the
        // calendar popover still lists it.
        menu.addItem(snoozeMenuItem(now: now))
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

    /// One "Snooze Meeting" leaf: which meeting, and the lead to snooze it
    /// to. A nil lead is "Show now", which clears the snooze.
    private struct SnoozeChoice {
        let key: String
        let lead: Int?
    }

    private func snoozeMenuItem(now: Date) -> NSMenuItem {
        let parent = NSMenuItem(title: "Snooze Meeting", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let snoozable = TrayModel.snoozableEvents(scheduler.cachedEvents, now: now, calendar: .current)
        if snoozable.isEmpty {
            let none = NSMenuItem(title: "No meetings left to snooze today", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for event in snoozable {
                let title = "\(Self.menuTimeFormatter.string(from: event.start))  \(event.title)"
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let choices = NSMenu()
                let active = scheduler.menuBarSnoozeLead(for: event)
                let leads = TrayModel.availableSnoozeLeads(for: event, now: now)
                if leads.isEmpty {
                    let none = NSMenuItem(title: "Too close to start", action: nil, keyEquivalent: "")
                    none.isEnabled = false
                    choices.addItem(none)
                }
                for lead in leads {
                    let label = lead < 60 ? "Until \(lead) minutes before" : "Until 1 hour before"
                    let choice = NSMenuItem(title: label, action: #selector(applySnooze(_:)), keyEquivalent: "")
                    choice.target = self
                    choice.representedObject = SnoozeChoice(key: event.schedulerKey, lead: lead)
                    choice.state = active == lead ? .on : .off
                    choices.addItem(choice)
                }
                if active != nil {
                    choices.addItem(.separator())
                    let show = NSMenuItem(title: "Show now", action: #selector(applySnooze(_:)), keyEquivalent: "")
                    show.target = self
                    show.representedObject = SnoozeChoice(key: event.schedulerKey, lead: nil)
                    choices.addItem(show)
                }
                entry.submenu = choices
                submenu.addItem(entry)
            }
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func applySnooze(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SnoozeChoice,
              let event = scheduler.cachedEvents.first(where: { $0.schedulerKey == choice.key }) else { return }
        if let lead = choice.lead {
            scheduler.snoozeMenuBar(event: event, leadMinutes: lead)
        } else {
            scheduler.clearMenuBarSnooze(event: event)
        }
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
        let state = TrayModel.state(events: scheduler.trayEvents, now: Date(),
                                    leadMinutes: settingsStore.settings.menuBarLeadMinutes)
        button.title = state.title.isEmpty ? "" : " \(state.title)"
        button.toolTip = state.tooltip
        if lastActive != state.showsMeeting {
            lastActive = state.showsMeeting
            let color = state.showsMeeting ? Self.activeColor : Self.doneColor
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

/// AppKit-side design tokens for the few places SwiftUI colours cannot
/// reach (status item tint, popover chrome). Harbor = accent, sage =
/// success; canvas mirrors YCDesignSystem.Colors.canvas in both themes.
enum YCDesignSystemNSColor {
    static let harbor = NSColor(red: 0x3E / 255.0, green: 0x6E / 255.0, blue: 0x93 / 255.0, alpha: 1)
    static let sage = NSColor(red: 0x3F / 255.0, green: 0x6A / 255.0, blue: 0x4E / 255.0, alpha: 1)
    static let canvas = dynamic(light: (0xFA, 0xF8, 0xF5), dark: (0x1B, 0x1D, 0x22))

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }
}

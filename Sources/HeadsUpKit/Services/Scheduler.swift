import Foundation

struct PlannedFiring: Equatable {
    let event: CalendarEvent
    let leadMinutes: Int
    let fireAt: Date
    var timerKey: String { "\(event.schedulerKey)@\(leadMinutes)" }

    init(event: CalendarEvent, leadMinutes: Int, fireAt: Date) {
        self.event = event
        self.leadMinutes = leadMinutes
        self.fireAt = fireAt
    }
}

/// Pure alert planning: which (event, leadMinutes) pairs should fire, and when.
enum AlertPlanner {
    static func plan(events: [CalendarEvent], settings: AppSettings, now: Date,
                     fired: Set<String>, snoozedKeys: Set<String>,
                     dismissedKeys: Set<String> = []) -> [PlannedFiring] {
        guard settings.alertsEnabled else { return [] }
        let leadTimes = Array(Set(settings.alertLeadTimes)).sorted(by: >)
        var out: [PlannedFiring] = []
        for event in events {
            if event.allDay { continue }
            if event.start <= now { continue }
            if snoozedKeys.contains(event.schedulerKey) { continue }
            // A user-dismissed event stays dismissed: no further lead-time
            // alerts for it, ever.
            if dismissedKeys.contains(event.schedulerKey) { continue }
            for lead in leadTimes {
                let firing = PlannedFiring(
                    event: event, leadMinutes: lead,
                    fireAt: event.start.addingTimeInterval(-Double(lead) * 60))
                if fired.contains(firing.timerKey) { continue }
                out.append(firing)
            }
        }
        return out
    }
}

/// Arms real timers from the planner's output, polls Google every minute,
/// and owns snooze state. Main-thread confined.
final class Scheduler {
    static let pollInterval: TimeInterval = 60
    static let scheduleHorizon: TimeInterval = 6 * 3600
    static let fetchDaysAhead = 30
    static let fetchDaysBack = 7

    private let calendarClient: GoogleCalendarClient
    private let settingsStore: SettingsStore
    private let registry: GoogleAccountsRegistry
    private let credentials: GoogleCredentialsStore
    private let showAlert: (CalendarEvent) -> Void
    private let now: () -> Date

    private(set) var cachedEvents: [CalendarEvent] = []
    private var pollTimer: Timer?
    private var alertTimers: [String: Timer] = [:]
    private var snoozeTimers: [String: Timer] = [:]
    private var snoozedKeys: Set<String> = []
    private var fired: Set<String> = []
    /// Events the user dismissed outright (Dismiss button, Join, Escape).
    /// No further lead-time alerts fire for these, unlike a fired key which
    /// only consumes one lead time.
    private var dismissedKeys: Set<String> = []
    private var eventsChangedObservers: [UUID: () -> Void] = [:]
    private var accountsStateObservers: [UUID: () -> Void] = [:]
    private var lastReconnectState = false
    private var lastCredentialsInvalidState = false

    init(calendarClient: GoogleCalendarClient, settingsStore: SettingsStore,
         registry: GoogleAccountsRegistry, credentials: GoogleCredentialsStore,
         showAlert: @escaping (CalendarEvent) -> Void,
         now: @escaping () -> Date = Date.init) {
        self.calendarClient = calendarClient
        self.settingsStore = settingsStore
        self.registry = registry
        self.credentials = credentials
        self.showAlert = showAlert
        self.now = now
    }

    var isConnected: Bool { credentials.isConfigured && registry.hasAccounts }

    // MARK: - Skipped meetings

    /// Meetings skipped from the menu bar: hidden from the tray title and
    /// alert-suppressed, persisted across relaunches in settings.
    var skippedKeys: Set<String> { Set(settingsStore.settings.skippedEvents) }

    /// Events for the menu bar surface: the cache minus skipped meetings.
    /// The calendar window keeps showing everything.
    var trayEvents: [CalendarEvent] {
        let skipped = skippedKeys
        return cachedEvents.filter { !skipped.contains($0.schedulerKey) }
    }

    func isSkipped(_ event: CalendarEvent) -> Bool {
        skippedKeys.contains(event.schedulerKey)
    }

    func skip(event: CalendarEvent) {
        let key = event.schedulerKey
        settingsStore.update { settings in
            if !settings.skippedEvents.contains(key) { settings.skippedEvents.append(key) }
        }
        // A pending snooze must not resurrect a skipped meeting's alert.
        snoozeTimers[key]?.invalidate()
        snoozeTimers[key] = nil
        snoozedKeys.remove(key)
        FileDiag.log("skip (event \(event.id.prefix(8))): meeting skipped from menu bar")
        rescheduleNow()
        notifyEventsChanged()
    }

    func unskip(event: CalendarEvent) {
        let key = event.schedulerKey
        settingsStore.update { settings in
            settings.skippedEvents.removeAll { $0 == key }
        }
        FileDiag.log("skip (event \(event.id.prefix(8))): meeting un-skipped")
        rescheduleNow()
        notifyEventsChanged()
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        Task { @MainActor in await self.refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        clearAlertTimers()
        for t in snoozeTimers.values { t.invalidate() }
        snoozeTimers = [:]
        snoozedKeys = []
        dismissedKeys = []
    }

    private func clearAlertTimers() {
        for t in alertTimers.values { t.invalidate() }
        alertTimers = [:]
    }

    // MARK: - Observers

    @discardableResult
    func onEventsChanged(_ cb: @escaping () -> Void) -> UUID {
        let id = UUID(); eventsChangedObservers[id] = cb; return id
    }
    func removeEventsChangedObserver(_ id: UUID) { eventsChangedObservers[id] = nil }

    @discardableResult
    func onAccountsStateChanged(_ cb: @escaping () -> Void) -> UUID {
        let id = UUID(); accountsStateObservers[id] = cb; return id
    }
    func removeAccountsStateChangedObserver(_ id: UUID) { accountsStateObservers[id] = nil }

    private func notifyEventsChanged() {
        for cb in eventsChangedObservers.values { cb() }
    }

    private func broadcastAccountsStateIfChanged() {
        let reconnect = registry.anyAccountNeedsReconnect
        let invalid = registry.credentialsInvalid
        if reconnect != lastReconnectState || invalid != lastCredentialsInvalidState {
            lastReconnectState = reconnect
            lastCredentialsInvalidState = invalid
            for cb in accountsStateObservers.values { cb() }
        }
    }

    // MARK: - Refresh + scheduling

    @MainActor
    func refresh() async {
        guard isConnected else {
            cachedEvents = []
            clearAlertTimers()
            notifyEventsChanged()
            broadcastAccountsStateIfChanged()
            return
        }
        guard let events = await calendarClient.upcomingEvents(
            daysAhead: Self.fetchDaysAhead, daysBack: Self.fetchDaysBack) else {
            // Wholesale fetch failure: every account failed, not just one
            // calendar. Keep the last good cache and armed timers untouched
            // rather than replacing them with an empty list, which would
            // silently disarm imminent alerts on a transient outage.
            NSLog("HeadsUp: calendar fetch failed for every account, keeping cached events")
            broadcastAccountsStateIfChanged()
            return
        }
        cachedEvents = events
        rescheduleNow()
        notifyEventsChanged()
        broadcastAccountsStateIfChanged()
    }

    /// Re-arm timers from the current cache. Call after settings changes too.
    func rescheduleNow() {
        clearAlertTimers()
        let current = now()
        // Bound `fired` over long uptimes: without this it only ever grows,
        // one entry per (event, leadMinutes) pair ever fired. Simplest
        // correct approach: keep a fired key only if its event is still
        // present in cachedEvents. Any key still matched by a live plan is
        // automatically covered by this too, since planned events are
        // always drawn from cachedEvents; a key whose event has fallen out
        // of the cache entirely (past the fetch window, cancelled, etc.) is
        // dropped.
        let currentEventKeys = Set(cachedEvents.map(\.schedulerKey))
        fired = fired.filter { firedKey in currentEventKeys.contains { firedKey.hasPrefix("\($0)@") } }
        dismissedKeys = dismissedKeys.intersection(currentEventKeys)
        // Prune skips whose events left the fetch window, but only when the
        // cache is non-empty and something actually went stale: this runs
        // every poll and must not rewrite settings.json each minute (or wipe
        // all skips on a transient empty cache before the first fetch).
        if !cachedEvents.isEmpty {
            let staleSkips = skippedKeys.subtracting(currentEventKeys)
            if !staleSkips.isEmpty {
                settingsStore.update { settings in
                    settings.skippedEvents.removeAll { staleSkips.contains($0) }
                }
            }
        }
        let plans = AlertPlanner.plan(events: cachedEvents, settings: settingsStore.settings,
                                      now: current, fired: fired, snoozedKeys: snoozedKeys,
                                      dismissedKeys: dismissedKeys.union(skippedKeys))
        for plan in plans {
            let delay = plan.fireAt.timeIntervalSince(current)
            if delay <= 0 {
                trigger(plan)
            } else if delay <= Self.scheduleHorizon {
                let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.trigger(plan)
                }
                alertTimers[plan.timerKey] = timer
            }
        }
    }

    private func trigger(_ plan: PlannedFiring) {
        alertTimers[plan.timerKey] = nil
        // A timer armed before a snooze started can still fire: active snooze wins.
        // Leave `fired` unset so this lead time re-arms once the snooze clears.
        if snoozedKeys.contains(plan.event.schedulerKey) { return }
        // Likewise a timer armed before the user dismissed or skipped it.
        if dismissedKeys.contains(plan.event.schedulerKey) { return }
        if skippedKeys.contains(plan.event.schedulerKey) { return }
        fired.insert(plan.timerKey)
        showAlert(plan.event)
    }

    /// The user dismissed this event's alert (Dismiss, Join, or Escape):
    /// suppress every remaining lead-time alert and any pending snooze for
    /// it. Other events are unaffected, and a plain snooze never comes here.
    func markDismissed(event: CalendarEvent) {
        let key = event.schedulerKey
        dismissedKeys.insert(key)
        snoozeTimers[key]?.invalidate()
        snoozeTimers[key] = nil
        snoozedKeys.remove(key)
        rescheduleNow()
    }

    /// Re-show the event after `minutes`, suppressing its other lead-time
    /// alerts until then. Does not affect other events.
    func snooze(event: CalendarEvent, minutes: Int) {
        let key = event.schedulerKey
        snoozeTimers[key]?.invalidate()
        snoozedKeys.insert(key)
        let timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.snoozeTimers[key] = nil
            self.snoozedKeys.remove(key)
            // A snooze started while alerts were on can still be pending
            // when the master alertsEnabled switch turns off; that must not
            // re-fire the full-screen alert. Clear the snooze bookkeeping
            // above either way so the event isn't left stuck "snoozed".
            guard self.settingsStore.settings.alertsEnabled else { return }
            self.showAlert(event)
        }
        snoozeTimers[key] = timer
    }
}

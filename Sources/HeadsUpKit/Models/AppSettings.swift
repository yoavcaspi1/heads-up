import Foundation

/// Non-sensitive app preferences. Mirrors the original settings-store.ts
/// schema, plus `appearance` (native replacement for Glaze's theme select).
struct AppSettings: Codable, Equatable {
    enum AlertBackground: String, Codable { case solid, blur }
    enum Appearance: String, Codable { case system, light, dark }
    /// Where a clicked calendar event opens: Google Calendar in the browser
    /// (the event's own web page), Apple Calendar at the event's time, or
    /// Notion Calendar on the event via its showEvent deep link.
    enum EventOpenTarget: String, Codable { case googleWeb, appleCalendar, notionCalendar }

    /// Minutes before an event starts to fire each of the two alerts.
    var alertLeadTimes: [Int]
    /// Minutes for each of the two quick-snooze buttons on the alert.
    var snoozeDurations: [Int]
    /// Master switch for full-screen alerts.
    var alertsEnabled: Bool
    /// Calendars excluded from sync and alerts, keyed "accountId::calendarId".
    var disabledCalendars: [String]
    /// Whether the menu bar item is shown.
    var menuBarCalendarEnabled: Bool
    /// Alert surface: opaque canvas colour, or native blur of what is behind.
    var alertBackground: AlertBackground
    /// Frosted-tint strength over the blur, 0...100. Blur mode only.
    var alertBlurIntensity: Int
    /// System / Light / Dark override for the whole app.
    var appearance: Appearance
    /// Which calendar app a clicked event opens in.
    var eventOpenTarget: EventOpenTarget
    /// Meetings the user skipped from the menu bar, keyed by schedulerKey
    /// (event id + start). A skipped meeting is hidden from the menu bar
    /// title and fires no alerts. Pruned by the scheduler once the event
    /// leaves the fetch window, so this never grows unbounded.
    var skippedEvents: [String]

    static let allowedLeadTimes = [0, 1, 2, 5, 10, 15, 30, 60]
    static let allowedSnoozeMinutes = [1, 2, 5, 10, 15, 30, 60]

    static let defaults = AppSettings(
        alertLeadTimes: [30, 5],
        snoozeDurations: [1, 5],
        alertsEnabled: true,
        disabledCalendars: [],
        menuBarCalendarEnabled: true,
        alertBackground: .solid,
        alertBlurIntensity: 30,
        appearance: .system,
        eventOpenTarget: .googleWeb,
        skippedEvents: []
    )

    /// Clamp every field to legal values, falling back per index to defaults,
    /// same semantics as the original sanitize().
    static func sanitized(from input: AppSettings) -> AppSettings {
        var out = input
        out.alertLeadTimes = sanitizedPair(
            input.alertLeadTimes, allowed: allowedLeadTimes, fallback: defaults.alertLeadTimes)
        out.snoozeDurations = sanitizedPair(
            input.snoozeDurations, allowed: allowedSnoozeMinutes, fallback: defaults.snoozeDurations)
        var seen = Set<String>()
        out.disabledCalendars = input.disabledCalendars.filter { seen.insert($0).inserted }
        var seenSkips = Set<String>()
        out.skippedEvents = input.skippedEvents.filter { seenSkips.insert($0).inserted }
        out.alertBlurIntensity = min(100, max(0, input.alertBlurIntensity))
        return out
    }

    private static func sanitizedPair(_ input: [Int], allowed: [Int], fallback: [Int]) -> [Int] {
        (0...1).map { i in
            let v = i < input.count ? input[i] : Int.min
            return allowed.contains(v) ? v : fallback[i]
        }
    }

    /// Decode leniently: unknown/missing fields fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        self.alertLeadTimes = (try? c.decode([Int].self, forKey: .alertLeadTimes)) ?? d.alertLeadTimes
        self.snoozeDurations = (try? c.decode([Int].self, forKey: .snoozeDurations)) ?? d.snoozeDurations
        self.alertsEnabled = (try? c.decode(Bool.self, forKey: .alertsEnabled)) ?? d.alertsEnabled
        self.disabledCalendars = (try? c.decode([String].self, forKey: .disabledCalendars)) ?? d.disabledCalendars
        self.menuBarCalendarEnabled = (try? c.decode(Bool.self, forKey: .menuBarCalendarEnabled)) ?? d.menuBarCalendarEnabled
        self.alertBackground = (try? c.decode(AlertBackground.self, forKey: .alertBackground)) ?? d.alertBackground
        self.alertBlurIntensity = (try? c.decode(Int.self, forKey: .alertBlurIntensity)) ?? d.alertBlurIntensity
        self.appearance = (try? c.decode(Appearance.self, forKey: .appearance)) ?? d.appearance
        self.eventOpenTarget = (try? c.decode(EventOpenTarget.self, forKey: .eventOpenTarget)) ?? d.eventOpenTarget
        self.skippedEvents = (try? c.decode([String].self, forKey: .skippedEvents)) ?? d.skippedEvents
        self = AppSettings.sanitized(from: self)
    }

    init(alertLeadTimes: [Int], snoozeDurations: [Int], alertsEnabled: Bool,
         disabledCalendars: [String], menuBarCalendarEnabled: Bool,
         alertBackground: AlertBackground, alertBlurIntensity: Int, appearance: Appearance,
         eventOpenTarget: EventOpenTarget = .googleWeb, skippedEvents: [String] = []) {
        self.alertLeadTimes = alertLeadTimes
        self.snoozeDurations = snoozeDurations
        self.alertsEnabled = alertsEnabled
        self.disabledCalendars = disabledCalendars
        self.menuBarCalendarEnabled = menuBarCalendarEnabled
        self.alertBackground = alertBackground
        self.alertBlurIntensity = alertBlurIntensity
        self.appearance = appearance
        self.eventOpenTarget = eventOpenTarget
        self.skippedEvents = skippedEvents
    }
}

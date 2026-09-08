import Foundation

/// Non-sensitive app preferences. Mirrors the original settings-store.ts
/// schema, plus `appearance` (native replacement for Glaze's theme select).
struct AppSettings: Codable, Equatable {
    enum AlertBackground: String, Codable {
        case solid
        case frosted

        /// Builds before the bundled backdrop called this mode "blur" and
        /// wrote that raw value into the settings file, so a user updating
        /// in place would otherwise silently drop back to `solid`.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "blur": self = .frosted
            default:
                guard let value = AlertBackground(rawValue: raw) else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "unknown alert background \"\(raw)\""))
                }
                self = value
            }
        }
    }
    enum Appearance: String, Codable { case system, light, dark }
    /// Where a clicked calendar event opens: Google Calendar in the browser
    /// (the event's own web page), Apple Calendar at the event's time, or
    /// Notion Calendar on the event via its showEvent deep link.
    enum EventOpenTarget: String, Codable { case googleWeb, appleCalendar, notionCalendar }
    /// Typeface for the full-screen alert title. Syne's heavy g/j descenders
    /// are flat-chopped by the typeface's design; DM Sans is the
    /// conventional-letterform alternative for people who read that as a
    /// rendering bug.
    enum AlertTitleFont: String, Codable { case syne, dmSans }

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
    /// Alert surface: opaque canvas colour, or the frosted bundled backdrop.
    var alertBackground: AlertBackground
    /// System / Light / Dark override for the whole app.
    var appearance: Appearance
    /// Which calendar app a clicked event opens in.
    var eventOpenTarget: EventOpenTarget
    /// Typeface used for the alert hero title.
    var alertTitleFont: AlertTitleFont
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
        alertBackground: .frosted,
        appearance: .system,
        eventOpenTarget: .googleWeb,
        alertTitleFont: .syne,
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
        self.appearance = (try? c.decode(Appearance.self, forKey: .appearance)) ?? d.appearance
        self.eventOpenTarget = (try? c.decode(EventOpenTarget.self, forKey: .eventOpenTarget)) ?? d.eventOpenTarget
        self.alertTitleFont = (try? c.decode(AlertTitleFont.self, forKey: .alertTitleFont)) ?? d.alertTitleFont
        self.skippedEvents = (try? c.decode([String].self, forKey: .skippedEvents)) ?? d.skippedEvents
        self = AppSettings.sanitized(from: self)
    }

    init(alertLeadTimes: [Int], snoozeDurations: [Int], alertsEnabled: Bool,
         disabledCalendars: [String], menuBarCalendarEnabled: Bool,
         alertBackground: AlertBackground, appearance: Appearance,
         eventOpenTarget: EventOpenTarget = .googleWeb, alertTitleFont: AlertTitleFont = .syne,
         skippedEvents: [String] = []) {
        self.alertLeadTimes = alertLeadTimes
        self.snoozeDurations = snoozeDurations
        self.alertsEnabled = alertsEnabled
        self.disabledCalendars = disabledCalendars
        self.menuBarCalendarEnabled = menuBarCalendarEnabled
        self.alertBackground = alertBackground
        self.appearance = appearance
        self.eventOpenTarget = eventOpenTarget
        self.alertTitleFont = alertTitleFont
        self.skippedEvents = skippedEvents
    }
}

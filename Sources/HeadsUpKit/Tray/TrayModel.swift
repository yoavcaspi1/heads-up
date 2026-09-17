import Foundation

struct TrayState: Equatable {
    let title: String
    let tooltip: String
    /// True when a meeting is being shown in the menu bar title, which is
    /// also what tints the bell active.
    let showsMeeting: Bool
}

/// Pure menu bar state derivation. All AppKit stays in TrayController.
enum TrayModel {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func countdown(minutes: Int) -> String {
        if minutes <= 0 { return "starting now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours < 24 { return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h" }
        let days = Int((Double(hours) / 24).rounded())
        return "in \(days)d"
    }

    /// Live accessory label shared by the tray and the calendar rows:
    /// countdown before start, "now" while in progress, nil once ended or
    /// for all-day events. One helper so the two surfaces cannot drift.
    static func liveLabel(for event: CalendarEvent, now: Date) -> String? {
        if event.allDay { return nil }
        if event.end <= now { return nil }
        if event.start > now {
            let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded())
            return countdown(minutes: minutes)
        }
        return "now"
    }

    /// Human label for the menu bar lead window, used in the empty-state
    /// tooltip: "45 min", "1 hour", "2 hours", "24 hours".
    static func leadWindowLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// The event(s) to show: next upcoming (plus simultaneous starters), else
    /// ongoing (plus simultaneous starters), else none. All-day excluded.
    static func nextEvents(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        let timed = events.filter { !$0.allDay }
        let upcoming = timed.filter { $0.start > now }.sorted { $0.start < $1.start }
        if let first = upcoming.first {
            return upcoming.filter { $0.start == first.start }
        }
        let ongoing = timed.filter { $0.end > now }.sorted { $0.start < $1.start }
        if let first = ongoing.first {
            return ongoing.filter { $0.start == first.start }
        }
        return []
    }

    /// Candidates for the menu bar's "Skip meeting" submenu: today's timed
    /// meetings that have not ended yet (upcoming or in progress), ascending
    /// by start. Includes already-skipped meetings so the menu can offer
    /// un-skip via checkmark.
    static func skippableEvents(_ events: [CalendarEvent], now: Date, calendar: Calendar) -> [CalendarEvent] {
        events
            .filter { !$0.allDay && $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start < $1.start }
    }

    // MARK: - Menu bar snooze

    /// Candidates for the "Snooze Meeting" submenu: the skippable list minus
    /// meetings already in progress, since a snooze can only hide something
    /// that has not started.
    static func snoozableEvents(_ events: [CalendarEvent], now: Date, calendar: Calendar) -> [CalendarEvent] {
        skippableEvents(events, now: now, calendar: calendar).filter { $0.start > now }
    }

    /// When a snoozed meeting comes back to the menu bar title: its start
    /// minus the chosen lead.
    static func snoozeRevealDate(event: CalendarEvent, leadMinutes: Int) -> Date {
        event.start.addingTimeInterval(-Double(leadMinutes) * 60)
    }

    /// The lead choices worth offering for a meeting: the standard ladder
    /// minus any whose reveal time has already gone by.
    static func availableSnoozeLeads(for event: CalendarEvent, now: Date) -> [Int] {
        AppSettings.allowedMenuBarSnoozeLeads.filter {
            snoozeRevealDate(event: event, leadMinutes: $0) > now
        }
    }

    /// True while a menu bar snooze is still hiding this meeting.
    static func isMenuBarSnoozed(event: CalendarEvent, snoozes: [String: Int], now: Date) -> Bool {
        guard let lead = snoozes[event.schedulerKey] else { return false }
        return now < snoozeRevealDate(event: event, leadMinutes: lead)
    }

    /// The events the menu bar title may draw from: the cache minus skipped
    /// meetings and minus meetings still inside their snooze. The calendar
    /// popover keeps showing everything.
    static func menuBarEvents(_ events: [CalendarEvent], skipped: Set<String>,
                              snoozes: [String: Int], now: Date) -> [CalendarEvent] {
        events.filter {
            !skipped.contains($0.schedulerKey)
                && !isMenuBarSnoozed(event: $0, snoozes: snoozes, now: now)
        }
    }

    /// Snooze entries that have served their purpose: the event has left the
    /// cache, or its reveal time has passed. The scheduler drops these so the
    /// dictionary never grows unbounded.
    static func staleMenuBarSnoozeKeys(_ snoozes: [String: Int], events: [CalendarEvent],
                                       now: Date) -> Set<String> {
        var byKey: [String: CalendarEvent] = [:]
        for event in events where byKey[event.schedulerKey] == nil {
            byKey[event.schedulerKey] = event
        }
        var stale: Set<String> = []
        for (key, lead) in snoozes {
            guard let event = byKey[key] else { stale.insert(key); continue }
            if snoozeRevealDate(event: event, leadMinutes: lead) <= now { stale.insert(key) }
        }
        return stale
    }

    /// `leadMinutes`: how far ahead of its start a meeting may appear in the
    /// title. A meeting already in progress shows whatever the window is.
    static func state(events: [CalendarEvent], now: Date, leadMinutes: Int) -> TrayState {
        let chosen = nextEvents(events, now: now)
        let window = Double(leadMinutes) * 60
        guard let first = chosen.first,
              first.start.timeIntervalSince(now) <= window else {
            return TrayState(title: "",
                             tooltip: "Heads Up - no meeting in the next \(leadWindowLabel(minutes: leadMinutes))",
                             showsMeeting: false)
        }
        let titles = chosen.map(\.title).joined(separator: " & ")
        // Same wording source as the calendar rows: countdown before start,
        // "now" while the fallback ongoing meeting is in progress.
        let live = liveLabel(for: first, now: now) ?? "now"
        let title = "\(titles) · \(clockFormatter.string(from: first.start)) (\(live))"
        let details = ["\(clockFormatter.string(from: first.start))-\(clockFormatter.string(from: first.end))",
                       first.calendarName, first.location]
            .compactMap { $0 }
            .joined(separator: " · ")
        return TrayState(title: title,
                         tooltip: "\(titles)\n\(details)",
                         showsMeeting: true)
    }
}

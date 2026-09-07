import Foundation

struct TrayState: Equatable {
    let title: String
    let tooltip: String
    let meetingsRemainToday: Bool
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

    /// The meeting the menu bar title is about: the first of `nextEvents`
    /// when it falls today, nil in the icon-only "no more meetings today"
    /// state. Clicking the tray opens the calendar scrolled to this event.
    static func focusEvent(_ events: [CalendarEvent], now: Date, calendar: Calendar) -> CalendarEvent? {
        guard let first = nextEvents(events, now: now).first,
              calendar.isDate(first.start, inSameDayAs: now) else { return nil }
        return first
    }

    static func state(events: [CalendarEvent], now: Date, calendar: Calendar) -> TrayState {
        let chosen = nextEvents(events, now: now)
        guard let first = focusEvent(events, now: now, calendar: calendar) else {
            return TrayState(title: "",
                             tooltip: "Heads Up - no more meetings today",
                             meetingsRemainToday: false)
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
                         meetingsRemainToday: true)
    }
}

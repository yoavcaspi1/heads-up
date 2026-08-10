import Foundation

/// Builds Notion Calendar's documented showEvent deep link
/// (cron://showEvent?accountEmail=…&iCalUID=…&startDate=…&endDate=…), per
/// https://www.notion.com/help/notion-calendar-integrations. Pure, so checks
/// can pin the exact URL shape without launching anything.
enum NotionCalendarLink {
    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The RFC5545 UID Notion Calendar keys events on. Google supplies it
    /// directly; if it is ever missing, derive it the way Google composes
    /// it: the event id minus any recurring-instance suffix, @google.com.
    static func icalUID(for event: CalendarEvent) -> String {
        if let uid = event.iCalUID, !uid.isEmpty { return uid }
        let base = event.id.split(separator: "_").first.map(String.init) ?? event.id
        return "\(base)@google.com"
    }

    static func showEventURL(for event: CalendarEvent) -> URL? {
        var comps = URLComponents()
        comps.scheme = "cron"
        comps.host = "showEvent"
        let format: (Date) -> String = event.allDay
            ? { dateOnly.string(from: $0) }
            : { timestamp.string(from: $0) }
        var items: [URLQueryItem] = []
        if let email = event.accountEmail {
            items.append(URLQueryItem(name: "accountEmail", value: email))
        }
        items.append(contentsOf: [
            URLQueryItem(name: "iCalUID", value: icalUID(for: event)),
            URLQueryItem(name: "startDate", value: format(event.start)),
            URLQueryItem(name: "endDate", value: format(event.end)),
            URLQueryItem(name: "title", value: event.title),
            URLQueryItem(name: "ref", value: "com.yoavcaspi.headsup"),
        ])
        comps.queryItems = items
        return comps.url
    }
}

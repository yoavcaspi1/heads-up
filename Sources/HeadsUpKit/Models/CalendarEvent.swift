import Foundation

struct CalendarEvent: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let meetingUrl: String?
    let meetingProvider: String?
    let accountEmail: String?
    let calendarName: String?
    let htmlLink: String?
    /// RFC5545 event UID from Google (master UID for recurring instances).
    /// Needed by the Notion Calendar showEvent deep link. Defaulted so the
    /// many existing construction sites stay source-compatible.
    var iCalUID: String? = nil
    /// True only for the Settings "Test alert" preview.
    var isTest: Bool = false

    /// Scheduler identity key: same event id can recur, so key on id + start.
    var schedulerKey: String { "\(id)@\(start.timeIntervalSince1970)" }
}

struct CalendarInfo: Codable, Equatable {
    /// "accountId::calendarId", stable across fetches.
    let key: String
    let accountEmail: String
    let calendarName: String
    let primary: Bool
}

struct GoogleAccount: Codable, Equatable, Identifiable {
    /// The account email doubles as the stable id.
    let id: String
    let email: String
    let name: String
    /// Keychain storage key prefix for this account's tokens.
    let providerId: String
    /// Runtime-only: token refresh hit invalid_grant, user must reconnect.
    var needsReconnect: Bool = false

    private enum CodingKeys: String, CodingKey { case id, email, name, providerId }
}

enum EventNormalizer {
    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseDate(_ dt: GoogleEventDateTime?) -> (date: Date, allDay: Bool)? {
        if let s = dt?.dateTime, let d = rfc3339.date(from: s) { return (d, false) }
        if let s = dt?.date, let d = dateOnly.date(from: s) { return (d, true) }
        return nil
    }

    static func normalize(_ raw: GoogleEvent, accountEmail: String, calendarName: String) -> CalendarEvent? {
        guard let id = raw.id, raw.status != "cancelled" else { return nil }
        guard let start = parseDate(raw.start), let end = parseDate(raw.end) else { return nil }
        let videoURI = raw.conferenceData?.entryPoints?
            .first { $0.entryPointType == "video" && $0.uri != nil }?.uri
        let meeting = MeetingLink.detect(location: raw.location, description: raw.description,
                                         hangoutLink: raw.hangoutLink, conferenceVideoURI: videoURI)
        let trimmedTitle = raw.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedLocation = raw.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            id: id,
            title: trimmedTitle.isEmpty ? "(No title)" : trimmedTitle,
            start: start.date,
            end: end.date,
            allDay: start.allDay,
            location: (trimmedLocation?.isEmpty ?? true) ? nil : trimmedLocation,
            meetingUrl: meeting.url,
            meetingProvider: meeting.provider,
            accountEmail: accountEmail,
            calendarName: calendarName,
            htmlLink: raw.htmlLink?.trimmingCharacters(in: .whitespaces),
            iCalUID: raw.iCalUID)
    }

    /// De-duplicate the same meeting appearing on multiple calendars/accounts
    /// (key: title|start|end), then sort ascending by start.
    static func mergeAndSort(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var seen = Set<String>()
        var merged: [CalendarEvent] = []
        for e in events {
            let key = "\(e.title)|\(e.start.timeIntervalSince1970)|\(e.end.timeIntervalSince1970)"
            if seen.insert(key).inserted { merged.append(e) }
        }
        return merged.sorted { $0.start < $1.start }
    }
}

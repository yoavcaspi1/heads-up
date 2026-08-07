import Foundation

/// Fetches calendars and events for every connected account over Google
/// Calendar REST v3, filters disabled calendars before fetching, and merges
/// everything into one normalised, de-duplicated, sorted list.
final class GoogleCalendarClient {
    private let registry: GoogleAccountsRegistry
    private let settingsStore: SettingsStore
    private let session: URLSession
    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(registry: GoogleAccountsRegistry, settingsStore: SettingsStore, session: URLSession = .shared) {
        self.registry = registry
        self.settingsStore = settingsStore
        self.session = session
    }

    static func calendarKey(accountId: String, calendarId: String) -> String {
        "\(accountId)::\(calendarId)"
    }

    static func calendarName(_ entry: CalendarListEntry, accountEmail: String) -> String {
        if let o = entry.summaryOverride, !o.isEmpty { return o }
        if let s = entry.summary, !s.isEmpty { return s }
        return (entry.primary ?? false) ? accountEmail : "Calendar"
    }

    private func apiGet<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OAuthError.transport("Google Calendar API error (\(status))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func listCalendars(token: String) async throws -> [CalendarListEntry] {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&showHidden=false")!
        let resp: GoogleCalendarListResponse = try await apiGet(url, token: token)
        return (resp.items ?? []).filter { $0.id != nil && $0.deleted != true && $0.hidden != true }
    }

    /// RFC 3986 unreserved characters, the correct encode-set for a URL path
    /// segment. `.alphanumerics` alone over-encodes "." (e.g. "a@x.com"
    /// becomes "a%40x%2Ecom" instead of "a%40x.com"), which does not match
    /// Google's own URL form for calendar ids.
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Follows `nextPageToken` to accumulate every event in the window, not
    /// just the first 50. Capped at 5 pages per calendar (250 events) as a
    /// sane upper bound; a single calendar routinely returning more than
    /// that in a 37-day window would indicate something pathological rather
    /// than a real gap to chase further.
    private static let maxPagesPerCalendar = 5

    private func fetchEvents(calendarId: String, token: String, timeMin: String, timeMax: String) async throws -> [GoogleEvent] {
        let encodedId = calendarId.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? calendarId
        var items: [GoogleEvent] = []
        var pageToken: String?
        var page = 0
        repeat {
            var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedId)/events")!
            var queryItems = [
                URLQueryItem(name: "timeMin", value: timeMin),
                URLQueryItem(name: "timeMax", value: timeMax),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "50"),
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = queryItems
            let resp: GoogleEventsResponse = try await apiGet(comps.url!, token: token)
            items.append(contentsOf: resp.items ?? [])
            pageToken = resp.nextPageToken
            page += 1
        } while pageToken != nil && page < Self.maxPagesPerCalendar
        return items
    }

    func listAllCalendars() async -> [CalendarInfo] {
        var out: [CalendarInfo] = []
        for account in registry.listAccounts() {
            guard let token = await registry.accessToken(for: account) else { continue }
            guard let calendars = try? await listCalendars(token: token) else { continue }
            for cal in calendars {
                guard let calId = cal.id else { continue }
                out.append(CalendarInfo(
                    key: Self.calendarKey(accountId: account.id, calendarId: calId),
                    accountEmail: account.email,
                    calendarName: Self.calendarName(cal, accountEmail: account.email),
                    primary: cal.primary ?? false))
            }
        }
        return out
    }

    /// Returns nil only when EVERY account failed wholesale (no calendar list
    /// retrievable for any account with a token, or no tokens at all while
    /// accounts exist), so callers can distinguish "no events" from "we
    /// couldn't ask Google" and keep showing the last good cache instead of
    /// silently disarming alerts. Partial per-calendar failures still degrade
    /// to their own successes, same as before: one flaky calendar's events
    /// endpoint 500ing does not drop the whole account, let alone the whole
    /// merged list, to nil.
    func upcomingEvents(daysAhead: Int, daysBack: Int) async -> [CalendarEvent]? {
        let accounts = registry.listAccounts()
        guard !accounts.isEmpty else { return [] }

        let now = Date()
        let timeMin = Self.rfc3339.string(from: now.addingTimeInterval(-Double(daysBack) * 86_400))
        let timeMax = Self.rfc3339.string(from: now.addingTimeInterval(Double(daysAhead) * 86_400))
        let disabled = Set(settingsStore.settings.disabledCalendars)

        var all: [CalendarEvent] = []
        var anyAccountSucceeded = false
        for account in accounts {
            guard let token = await registry.accessToken(for: account) else { continue }
            guard let calendars = try? await listCalendars(token: token) else { continue }
            anyAccountSucceeded = true
            let enabled = calendars.filter { cal in
                guard let calId = cal.id else { return false }
                return !disabled.contains(Self.calendarKey(accountId: account.id, calendarId: calId))
            }
            await withTaskGroup(of: [CalendarEvent].self) { group in
                for cal in enabled {
                    guard let calId = cal.id else { continue }
                    let name = Self.calendarName(cal, accountEmail: account.email)
                    group.addTask {
                        guard let raw = try? await self.fetchEvents(
                            calendarId: calId, token: token, timeMin: timeMin, timeMax: timeMax) else { return [] }
                        return raw.compactMap {
                            EventNormalizer.normalize($0, accountEmail: account.email, calendarName: name)
                        }
                    }
                }
                for await chunk in group { all.append(contentsOf: chunk) }
            }
        }
        guard anyAccountSucceeded else { return nil }
        return EventNormalizer.mergeAndSort(all)
    }
}

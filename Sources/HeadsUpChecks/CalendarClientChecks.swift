@testable import HeadsUpKit
import Foundation

final class StubURLProtocol: URLProtocol {
    /// URL-substring -> (status, JSON body) fixtures.
    nonisolated(unsafe) static var fixtures: [(match: String, status: Int, body: String)] = []
    /// Every request URL actually seen by startLoading, in order. Lets a test
    /// prove a given endpoint was (or was not) hit, not just infer it from
    /// the response, which a missing fixture cannot distinguish from a
    /// fetch-then-404-then-degrade-to-empty path.
    nonisolated(unsafe) static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.requestedURLs.append(url)
        let fixture = Self.fixtures.first { url.contains($0.match) }
            ?? (match: "", status: 404, body: "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeEnv() -> (session: URLSession, registry: GoogleAccountsRegistry, settings: SettingsStore) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("headsup-test-\(UUID().uuidString)")
    let secrets = InMemorySecretStore()
    let creds = GoogleCredentialsStore(secrets: secrets)
    creds.save(clientId: "id", clientSecret: "sec")
    let registry = GoogleAccountsRegistry(directory: dir, oauth: GoogleOAuth(credentials: creds, secrets: secrets))
    registry.addAccountRecord(GoogleAccount(id: "a@x.com", email: "a@x.com", name: "A", providerId: "google-1"))
    registry.setTokenFetcher { _ in "token" }
    let settings = SettingsStore(directory: dir)

    return (session, registry, settings)
}

func calendarClientTests() async {
    suite("CalendarClientTests")

    await test("testListAllCalendars") {
        let (session, registry, settings) = makeEnv()
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.fixtures = [
            (match: "users/me/calendarList", status: 200, body: """
             {"items": [
               {"id": "a@x.com", "summary": "A cal", "primary": true},
               {"id": "team@group.calendar.google.com", "summary": "Team", "summaryOverride": "Team Shared"},
               {"id": "gone", "deleted": true}
             ]}
             """)
        ]
        let client = GoogleCalendarClient(registry: registry, settingsStore: settings, session: session)
        let cals = await client.listAllCalendars()
        try expectEqual(cals.count, 2)
        try expectEqual(cals[0].key, "a@x.com::a@x.com")
        try expect(cals[0].primary)
        try expectEqual(cals[1].calendarName, "Team Shared")
    }

    await test("testUpcomingEventsSkipsDisabledCalendar") {
        let (session, registry, settings) = makeEnv()
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.fixtures = [
            (match: "users/me/calendarList", status: 200, body: """
             {"items": [
               {"id": "a@x.com", "summary": "A cal", "primary": true},
               {"id": "muted-cal", "summary": "Muted"}
             ]}
             """),
            (match: "calendars/a%40x.com/events", status: 200, body: """
             {"items": [{"id": "e1", "summary": "Standup",
               "start": {"dateTime": "2026-07-29T10:00:00+01:00"},
               "end": {"dateTime": "2026-07-29T10:30:00+01:00"}}]}
             """),
            (match: "calendars/muted-cal/events", status: 200, body: """
             {"items": [{"id": "e2", "summary": "Should not appear",
               "start": {"dateTime": "2026-07-29T11:00:00+01:00"},
               "end": {"dateTime": "2026-07-29T11:30:00+01:00"}}]}
             """)
        ]
        settings.update { $0.disabledCalendars = ["a@x.com::muted-cal"] }
        let client = GoogleCalendarClient(registry: registry, settingsStore: settings, session: session)
        let events = await client.upcomingEvents(daysAhead: 30, daysBack: 7)
        try expectEqual(events?.map(\.title) ?? [], ["Standup"])
    }

    // Extra check beyond the brief: proves the disabled calendar's events
    // endpoint is never hit at all, not merely that its event is filtered
    // out afterwards. Deliberately keeps a POISONED fixture for
    // muted-cal/events (200, with an event that would appear if fetched) so
    // that omitting the fixture cannot be confused with genuinely skipping
    // the request: if the client ever fetched it, the fixture would happily
    // answer 200 and the filtering would have to happen downstream instead
    // of before the request, which is exactly the behaviour under test.
    // Asserts both the result AND that StubURLProtocol never recorded a
    // request whose URL contains "muted-cal/events".
    await test("disabled calendar endpoint is never fetched") {
        let (session, registry, settings) = makeEnv()
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.fixtures = [
            (match: "users/me/calendarList", status: 200, body: """
             {"items": [
               {"id": "a@x.com", "summary": "A cal", "primary": true},
               {"id": "muted-cal", "summary": "Muted"}
             ]}
             """),
            (match: "calendars/a%40x.com/events", status: 200, body: """
             {"items": [{"id": "e1", "summary": "Standup",
               "start": {"dateTime": "2026-07-29T10:00:00+01:00"},
               "end": {"dateTime": "2026-07-29T10:30:00+01:00"}}]}
             """),
            (match: "calendars/muted-cal/events", status: 200, body: """
             {"items": [{"id": "e2", "summary": "Should not appear",
               "start": {"dateTime": "2026-07-29T11:00:00+01:00"},
               "end": {"dateTime": "2026-07-29T11:30:00+01:00"}}]}
             """)
        ]
        settings.update { $0.disabledCalendars = ["a@x.com::muted-cal"] }
        let client = GoogleCalendarClient(registry: registry, settingsStore: settings, session: session)
        let events = await client.upcomingEvents(daysAhead: 30, daysBack: 7)
        try expectEqual(events?.map(\.title) ?? [], ["Standup"])
        try expect(!StubURLProtocol.requestedURLs.contains { $0.contains("muted-cal/events") },
                    "muted-cal/events endpoint should never be requested")
    }

    // Two-page fixture: page one's response carries a nextPageToken and one
    // event, page two is keyed by the pageToken query substring and carries
    // the second event. The specific "pageToken=PAGE2" fixture is listed
    // before the generic events-endpoint fixture so it wins the first-match
    // lookup for the second request while the first request (no pageToken
    // yet) still falls through to the generic one.
    await test("testEventsPagination") {
        let (session, registry, settings) = makeEnv()
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.fixtures = [
            (match: "users/me/calendarList", status: 200, body: """
             {"items": [{"id": "a@x.com", "summary": "A cal", "primary": true}]}
             """),
            (match: "pageToken=PAGE2", status: 200, body: """
             {"items": [{"id": "e2", "summary": "Page two event",
               "start": {"dateTime": "2026-07-29T11:00:00+01:00"},
               "end": {"dateTime": "2026-07-29T11:30:00+01:00"}}]}
             """),
            (match: "calendars/a%40x.com/events", status: 200, body: """
             {"items": [{"id": "e1", "summary": "Page one event",
               "start": {"dateTime": "2026-07-29T10:00:00+01:00"},
               "end": {"dateTime": "2026-07-29T10:30:00+01:00"}}],
              "nextPageToken": "PAGE2"}
             """)
        ]
        let client = GoogleCalendarClient(registry: registry, settingsStore: settings, session: session)
        let events = await client.upcomingEvents(daysAhead: 30, daysBack: 7)
        try expectEqual(Set(events?.map(\.title) ?? []), Set(["Page one event", "Page two event"]))
        try expect(StubURLProtocol.requestedURLs.contains { $0.contains("pageToken=PAGE2") },
                    "second page should have been requested with the pageToken")
    }

    await test("wholesale failure returns nil") {
        let (session, registry, settings) = makeEnv()
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.fixtures = [
            (match: "users/me/calendarList", status: 500, body: "{}")
        ]
        let client = GoogleCalendarClient(registry: registry, settingsStore: settings, session: session)
        let events = await client.upcomingEvents(daysAhead: 30, daysBack: 7)
        try expectNil(events)
    }

    // One account, calendar list retrievable, one calendar's events endpoint
    // 500s and the other succeeds: a per-calendar failure must degrade to its
    // own empty contribution, not poison the whole account into nil.
    await test("partial failure keeps successes") {
        let (session, registry, settings) = makeEnv()
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.fixtures = [
            (match: "users/me/calendarList", status: 200, body: """
             {"items": [
               {"id": "a@x.com", "summary": "A cal", "primary": true},
               {"id": "flaky-cal", "summary": "Flaky"}
             ]}
             """),
            (match: "calendars/a%40x.com/events", status: 200, body: """
             {"items": [{"id": "e1", "summary": "Standup",
               "start": {"dateTime": "2026-07-29T10:00:00+01:00"},
               "end": {"dateTime": "2026-07-29T10:30:00+01:00"}}]}
             """),
            (match: "calendars/flaky-cal/events", status: 500, body: "{}")
        ]
        let client = GoogleCalendarClient(registry: registry, settingsStore: settings, session: session)
        let events = await client.upcomingEvents(daysAhead: 30, daysBack: 7)
        try expectNotNil(events)
        try expectEqual(events?.map(\.title), ["Standup"])
    }
}

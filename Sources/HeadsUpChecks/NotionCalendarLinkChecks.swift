@testable import HeadsUpKit
import Foundation

private func linkEvent(id: String = "ev1", allDay: Bool = false,
                       accountEmail: String? = "alex@example.com",
                       iCalUID: String? = "ev1@google.com") -> CalendarEvent {
    CalendarEvent(id: id, title: "New Sites",
                  start: Date(timeIntervalSince1970: 1_786_100_400),   // 2026-08-07T11:00:00Z
                  end: Date(timeIntervalSince1970: 1_786_105_800),     // 2026-08-07T12:30:00Z
                  allDay: allDay, location: nil, meetingUrl: nil, meetingProvider: nil,
                  accountEmail: accountEmail, calendarName: "Work", htmlLink: nil,
                  iCalUID: iCalUID)
}

func notionCalendarLinkTests() async {
    suite("NotionCalendarLinkTests")

    await test("testShowEventURLForTimedEvent") {
        let url = NotionCalendarLink.showEventURL(for: linkEvent())
        try expectEqual(url?.scheme, "cron")
        try expectEqual(url?.host, "showEvent")
        let s = url?.absoluteString ?? ""
        try expect(s.contains("accountEmail=alex@example.com"))
        try expect(s.contains("iCalUID=ev1@google.com"))
        try expect(s.contains("startDate=2026-08-07T11:00:00.000Z"))
        try expect(s.contains("endDate=2026-08-07T12:30:00.000Z"))
        try expect(s.contains("title=New%20Sites"))
        try expect(s.contains("ref=com.yoavcaspi.headsup"))
    }

    await test("testAllDayUsesDateOnlyFormat") {
        let url = NotionCalendarLink.showEventURL(for: linkEvent(allDay: true))
        let s = url?.absoluteString ?? ""
        // Local-calendar date, no time component.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let expected = f.string(from: Date(timeIntervalSince1970: 1_786_100_400))
        try expect(s.contains("startDate=\(expected)"))
        try expect(!s.contains("startDate=\(expected)T"))
    }

    await test("testICalUIDFallbackDerivedFromRecurringInstanceId") {
        // No iCalUID from the API: derive Google's composition, stripping
        // the recurring-instance suffix from the id.
        let derived = NotionCalendarLink.icalUID(
            for: linkEvent(id: "abc123_20260807T120000Z", iCalUID: nil))
        try expectEqual(derived, "abc123@google.com")
        let passthrough = NotionCalendarLink.icalUID(for: linkEvent())
        try expectEqual(passthrough, "ev1@google.com")
    }

    await test("testMissingAccountEmailOmitsParameter") {
        let url = NotionCalendarLink.showEventURL(for: linkEvent(accountEmail: nil))
        try expect(!(url?.absoluteString ?? "").contains("accountEmail"))
    }
}

@testable import HeadsUpKit
import Foundation

func eventNormalizationTests() async {
    suite("EventNormalizationTests")

    await test("testNormalizeTimedEvent") {
        let e = EventNormalizer.normalize(makeRaw(), accountEmail: "a@x.com", calendarName: "Work")
        try expectNotNil(e)
        try expectEqual(e?.title, "Standup")
        try expect(!(e?.allDay ?? true))
        try expectEqual(e?.accountEmail, "a@x.com")
        try expectEqual(e?.calendarName, "Work")
    }

    await test("testCancelledAndIdlessDropped") {
        try expectNil(EventNormalizer.normalize(makeRaw(status: "cancelled"), accountEmail: "a", calendarName: "c"))
        try expectNil(EventNormalizer.normalize(makeRaw(id: nil), accountEmail: "a", calendarName: "c"))
    }

    await test("testAllDayDetected") {
        let raw = makeRaw(startDateTime: nil, startDate: "2026-07-29", endDateTime: nil, endDate: "2026-07-30")
        let e = EventNormalizer.normalize(raw, accountEmail: "a", calendarName: "c")
        try expectEqual(e?.allDay, true)
    }

    await test("testEmptyTitleBecomesNoTitle") {
        let e = EventNormalizer.normalize(makeRaw(summary: "  "), accountEmail: "a", calendarName: "c")
        try expectEqual(e?.title, "(No title)")
    }

    await test("testMergeDedupesByTitleStartEndAndSorts") {
        let a = EventNormalizer.normalize(makeRaw(), accountEmail: "a@x.com", calendarName: "Work")!
        let dup = EventNormalizer.normalize(makeRaw(), accountEmail: "b@y.com", calendarName: "Shared")!
        let later = EventNormalizer.normalize(
            makeRaw(id: "e2", summary: "Later",
                    startDateTime: "2026-07-29T12:00:00+01:00",
                    endDateTime: "2026-07-29T13:00:00+01:00"),
            accountEmail: "a@x.com", calendarName: "Work")!
        let merged = EventNormalizer.mergeAndSort([later, a, dup])
        try expectEqual(merged.count, 2)
        try expectEqual(merged[0].title, "Standup")   // sorted by start
        try expectEqual(merged[1].title, "Later")
    }

    await test("testICalUIDCarriedThrough") {
        let e = EventNormalizer.normalize(makeRaw(iCalUID: "abc@google.com"),
                                          accountEmail: "alex@example.com", calendarName: "Work")
        try expectEqual(e?.iCalUID, "abc@google.com")
    }
}

// File-private helper
private func makeRaw(id: String? = "e1", status: String? = "confirmed",
                     summary: String? = "Standup",
                     startDateTime: String? = "2026-07-29T10:00:00+01:00",
                     startDate: String? = nil,
                     endDateTime: String? = "2026-07-29T10:30:00+01:00",
                     endDate: String? = nil,
                     iCalUID: String? = nil) -> GoogleEvent {
    GoogleEvent(
        id: id, iCalUID: iCalUID, status: status, summary: summary, location: nil, description: nil,
        hangoutLink: nil, htmlLink: "https://calendar.google.com/event?eid=x",
        start: GoogleEventDateTime(date: startDate, dateTime: startDateTime),
        end: GoogleEventDateTime(date: endDate, dateTime: endDateTime),
        conferenceData: nil)
}

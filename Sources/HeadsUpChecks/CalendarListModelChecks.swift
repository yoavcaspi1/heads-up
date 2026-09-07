@testable import HeadsUpKit
import Foundation

fileprivate let calendarListChecksNow = Date()

fileprivate func calendarListChecksEvent(_ title: String, dayOffset: Int) -> CalendarEvent {
    let cal = Calendar.current
    let start = cal.date(byAdding: .day, value: dayOffset, to: calendarListChecksNow)!
    return CalendarEvent(id: title, title: title, start: start, end: start.addingTimeInterval(1800),
                          allDay: false, location: nil, meetingUrl: nil, meetingProvider: nil,
                          accountEmail: nil, calendarName: nil, htmlLink: nil)
}

func calendarListModelTests() async {
    suite("CalendarListModelTests")

    await test("testDayLabelKnownOffsets") {
        let today = Date()
        try expectEqual(CalendarListModel.dayLabel(offset: 0, date: today), "Today")
        try expectEqual(CalendarListModel.dayLabel(offset: 1, date: today), "Tomorrow")
        try expectEqual(CalendarListModel.dayLabel(offset: -1, date: today), "Yesterday")
    }

    await test("testDayLabelFarOffsetUsesWeekdayFormat") {
        // Fixed date (not "today ± N") so the expected string is
        // deterministic run to run, computed independently against the
        // "EEEE d MMM" spec format rather than re-deriving it from the
        // source, so a regression in the format string itself is caught.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 12
        let fixedDate = Calendar.current.date(from: comps)!
        let expectedFormatter = DateFormatter()
        expectedFormatter.dateFormat = "EEEE d MMM"
        let label = CalendarListModel.dayLabel(offset: 5, date: fixedDate)
        try expectEqual(label, expectedFormatter.string(from: fixedDate))
    }

    await test("testScrollTargetPrefersRequestedEvent") {
        let today = calendarListChecksEvent("Today", dayOffset: 0)
        let tomorrow = calendarListChecksEvent("Tomorrow", dayOffset: 1)
        let sections = CalendarListModel.bucketed([today, tomorrow], today: calendarListChecksNow, calendar: .current)
        let request = CalendarScrollRequest(eventKey: tomorrow.schedulerKey)
        try expectEqual(CalendarListModel.scrollTargetId(for: request, sections: sections),
                        CalendarListModel.rowId(forEventKey: tomorrow.schedulerKey))
    }

    await test("testScrollTargetFallsBackToTodayAnchor") {
        let yesterday = calendarListChecksEvent("Yesterday", dayOffset: -1)
        let dayAfter = calendarListChecksEvent("DayAfter", dayOffset: 2)
        let sections = CalendarListModel.bucketed([yesterday, dayAfter], today: calendarListChecksNow, calendar: .current)
        // No request at all, and a request for an event no longer cached:
        // both land on the first section at or after today, never on the
        // past.
        try expectEqual(CalendarListModel.scrollTargetId(for: nil, sections: sections),
                        CalendarListModel.sectionId(forDayOffset: 2))
        let stale = CalendarScrollRequest(eventKey: "gone@0")
        try expectEqual(CalendarListModel.scrollTargetId(for: stale, sections: sections),
                        CalendarListModel.sectionId(forDayOffset: 2))
        try expectNil(CalendarListModel.scrollTargetId(for: nil, sections: []))
    }

    await test("testScrollRequestsAreDistinct") {
        // Same target twice must still compare unequal so onChange fires
        // on a re-open.
        try expect(CalendarScrollRequest(eventKey: "a@1") != CalendarScrollRequest(eventKey: "a@1"))
    }

    await test("testBucketingExcludesBeyondOneWeek") {
        // Calls the real static bucketing function directly (extracted from
        // CalendarListModel.sections), since building a full model needs a
        // live Scheduler.
        let events = [
            calendarListChecksEvent("InRange", dayOffset: 7),
            calendarListChecksEvent("OutOfRange", dayOffset: 8),
        ]
        let sections = CalendarListModel.bucketed(events, today: calendarListChecksNow, calendar: Calendar.current)
        try expect(sections.first { $0.dayOffset == 7 }?.events.map(\.title) == ["InRange"])
        try expectNil(sections.first { $0.dayOffset == 8 })
    }
}

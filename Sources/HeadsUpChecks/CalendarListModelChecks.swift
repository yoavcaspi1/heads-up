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

    await test("testEveryDayInWindowGetsASection") {
        // One event a few days out; every other day, today included, must
        // still appear with an empty body so the list reads as a fortnight.
        let sections = CalendarListModel.bucketed([calendarListChecksEvent("Thu", dayOffset: 3)],
                                                  today: calendarListChecksNow, calendar: .current)
        try expectEqual(sections.map(\.dayOffset), Array(CalendarListModel.dayWindow))
        try expectEqual(sections.first { $0.dayOffset == 3 }?.events.map(\.title), ["Thu"])
        try expect(sections.first { $0.dayOffset == 0 }?.events.isEmpty == true)
        try expect(sections.first { $0.dayOffset == -7 }?.events.isEmpty == true)
    }

    await test("testScrollTargetIsTodayEvenWhenEmpty") {
        let sections = CalendarListModel.bucketed([calendarListChecksEvent("Later", dayOffset: 2)],
                                                  today: calendarListChecksNow, calendar: .current)
        try expectEqual(CalendarListModel.scrollTargetId(sections: sections),
                        CalendarListModel.sectionId(forDayOffset: 0))
        try expectNil(CalendarListModel.scrollTargetId(sections: []))
    }

    await test("testScrollRequestsAreDistinct") {
        // Two opens in a row must produce unequal requests so onChange
        // fires the second time.
        try expect(CalendarScrollRequest() != CalendarScrollRequest())
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

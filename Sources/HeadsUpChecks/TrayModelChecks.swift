@testable import HeadsUpKit
import Foundation

// Fixed "now": build events relative to it, on today's date.
fileprivate let trayChecksNow = Date()

fileprivate func trayChecksEvent(_ title: String, startMin: Int, endMin: Int, allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(id: title, title: title,
                  start: trayChecksNow.addingTimeInterval(Double(startMin) * 60),
                  end: trayChecksNow.addingTimeInterval(Double(endMin) * 60),
                  allDay: allDay, location: nil, meetingUrl: nil, meetingProvider: nil,
                  accountEmail: nil, calendarName: "Work", htmlLink: nil)
}

func trayModelTests() async {
    suite("TrayModelTests")

    await test("testPrefersUpcomingOverOngoing") {
        let ongoing = trayChecksEvent("Ongoing", startMin: -10, endMin: 20)
        let next = trayChecksEvent("Next", startMin: 15, endMin: 45)
        try expectEqual(TrayModel.nextEvents([ongoing, next], now: trayChecksNow).map(\.title), ["Next"])
    }

    await test("testFallsBackToOngoing") {
        let ongoing = trayChecksEvent("Ongoing", startMin: -10, endMin: 20)
        try expectEqual(TrayModel.nextEvents([ongoing], now: trayChecksNow).map(\.title), ["Ongoing"])
    }

    await test("testSimultaneousMeetingsJoined") {
        let a = trayChecksEvent("A", startMin: 15, endMin: 45)
        let b = trayChecksEvent("B", startMin: 15, endMin: 60)
        let state = TrayModel.state(events: [a, b], now: trayChecksNow, calendar: .current)
        try expect(state.title.hasPrefix("A & B") || state.title.hasPrefix("B & A"))
        try expect(state.meetingsRemainToday)
    }

    await test("testAllDayIgnored") {
        let allDay = trayChecksEvent("AllDay", startMin: 60, endMin: 120, allDay: true)
        try expect(TrayModel.nextEvents([allDay], now: trayChecksNow).isEmpty)
    }

    await test("testTomorrowMeetingShowsIconOnly") {
        let tomorrow = trayChecksEvent("Tomorrow", startMin: 60 * 26, endMin: 60 * 27)
        let state = TrayModel.state(events: [tomorrow], now: trayChecksNow, calendar: .current)
        try expectEqual(state.title, "")
        try expect(!state.meetingsRemainToday)
        try expect(state.tooltip.contains("no more meetings today"))
    }

    await test("testCountdownFormats") {
        try expectEqual(TrayModel.countdown(minutes: 0), "starting now")
        try expectEqual(TrayModel.countdown(minutes: 12), "in 12 min")
        try expectEqual(TrayModel.countdown(minutes: 90), "in 1h 30m")
        try expectEqual(TrayModel.countdown(minutes: 120), "in 2h")
        try expectEqual(TrayModel.countdown(minutes: 60 * 50), "in 2d")
    }

    await test("testLiveLabelStates") {
        let upcoming = trayChecksEvent("Upcoming", startMin: 15, endMin: 45)
        try expectEqual(TrayModel.liveLabel(for: upcoming, now: trayChecksNow), "in 15 min")

        let inProgress = trayChecksEvent("InProgress", startMin: -10, endMin: 20)
        try expectEqual(TrayModel.liveLabel(for: inProgress, now: trayChecksNow), "now")

        let ended = trayChecksEvent("Ended", startMin: -60, endMin: -30)
        try expectNil(TrayModel.liveLabel(for: ended, now: trayChecksNow))

        let allDay = trayChecksEvent("AllDay", startMin: -60, endMin: 60 * 12, allDay: true)
        try expectNil(TrayModel.liveLabel(for: allDay, now: trayChecksNow))
    }

    await test("testOngoingTrayTitleSaysNow") {
        let ongoing = trayChecksEvent("Ongoing", startMin: -10, endMin: 20)
        let state = TrayModel.state(events: [ongoing], now: trayChecksNow, calendar: .current)
        try expect(state.title.contains("(now)"))
    }

    await test("testSkippableEventsTodayNotEndedOnly") {
        let ended = trayChecksEvent("Ended", startMin: -60, endMin: -10)
        let ongoing = trayChecksEvent("Ongoing", startMin: -10, endMin: 20)
        let upcoming = trayChecksEvent("Upcoming", startMin: 30, endMin: 60)
        let allDay = trayChecksEvent("AllDay", startMin: 30, endMin: 90, allDay: true)
        let tomorrow = trayChecksEvent("Tomorrow", startMin: 60 * 26, endMin: 60 * 27)
        let out = TrayModel.skippableEvents([tomorrow, upcoming, allDay, ongoing, ended],
                                            now: trayChecksNow, calendar: .current)
        try expectEqual(out.map(\.title), ["Ongoing", "Upcoming"])
    }
}

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
        let state = TrayModel.state(events: [a, b], now: trayChecksNow, leadMinutes: 1440)
        try expect(state.title.hasPrefix("A & B") || state.title.hasPrefix("B & A"))
        try expect(state.showsMeeting)
    }

    await test("testAllDayIgnored") {
        let allDay = trayChecksEvent("AllDay", startMin: 60, endMin: 120, allDay: true)
        try expect(TrayModel.nextEvents([allDay], now: trayChecksNow).isEmpty)
    }

    await test("testMeetingBeyondWindowShowsIconOnly") {
        // 90 minutes out: inside a 2 hour window, outside a 1 hour one.
        let later = trayChecksEvent("Later", startMin: 90, endMin: 120)
        let shown = TrayModel.state(events: [later], now: trayChecksNow, leadMinutes: 120)
        try expect(shown.title.hasPrefix("Later"))
        try expect(shown.showsMeeting)

        let hidden = TrayModel.state(events: [later], now: trayChecksNow, leadMinutes: 60)
        try expectEqual(hidden.title, "")
        try expect(!hidden.showsMeeting)
        try expect(hidden.tooltip.contains("no meeting in the next 1 hour"))
    }

    await test("testOngoingMeetingShowsRegardlessOfWindow") {
        let ongoing = trayChecksEvent("Ongoing", startMin: -10, endMin: 50)
        let state = TrayModel.state(events: [ongoing], now: trayChecksNow, leadMinutes: 1)
        try expect(state.title.hasPrefix("Ongoing"))
        try expect(state.showsMeeting)
    }

    await test("testTomorrowMeetingNeedsTheFullDayWindow") {
        // 26 hours out: hidden even at the widest window; 20 hours out shows.
        let tomorrow = trayChecksEvent("Tomorrow", startMin: 60 * 26, endMin: 60 * 27)
        let outside = TrayModel.state(events: [tomorrow], now: trayChecksNow, leadMinutes: 1440)
        try expectEqual(outside.title, "")
        try expect(!outside.showsMeeting)
        try expect(outside.tooltip.contains("no meeting in the next 24 hours"))

        let tonight = trayChecksEvent("Tonight", startMin: 60 * 20, endMin: 60 * 21)
        let inside = TrayModel.state(events: [tonight], now: trayChecksNow, leadMinutes: 1440)
        try expect(inside.showsMeeting)
        let narrow = TrayModel.state(events: [tonight], now: trayChecksNow, leadMinutes: 720)
        try expect(!narrow.showsMeeting)
    }

    await test("testLeadWindowLabel") {
        try expectEqual(TrayModel.leadWindowLabel(minutes: 1), "1 min")
        try expectEqual(TrayModel.leadWindowLabel(minutes: 45), "45 min")
        try expectEqual(TrayModel.leadWindowLabel(minutes: 60), "1 hour")
        try expectEqual(TrayModel.leadWindowLabel(minutes: 120), "2 hours")
        try expectEqual(TrayModel.leadWindowLabel(minutes: 1440), "24 hours")
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
        let state = TrayModel.state(events: [ongoing], now: trayChecksNow, leadMinutes: 1440)
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

    await test("testSnoozableExcludesMeetingsAlreadyStarted") {
        let ongoing = trayChecksEvent("Ongoing", startMin: -10, endMin: 20)
        let upcoming = trayChecksEvent("Upcoming", startMin: 30, endMin: 60)
        let out = TrayModel.snoozableEvents([ongoing, upcoming], now: trayChecksNow, calendar: .current)
        try expectEqual(out.map(\.title), ["Upcoming"])
    }

    await test("testAvailableSnoozeLeadsDropPastRevealTimes") {
        // 20 minutes out: 5, 10 and 15 still lie ahead; 30 and 60 do not.
        let soon = trayChecksEvent("Soon", startMin: 20, endMin: 50)
        try expectEqual(TrayModel.availableSnoozeLeads(for: soon, now: trayChecksNow), [5, 10, 15])
        let later = trayChecksEvent("Later", startMin: 180, endMin: 210)
        try expectEqual(TrayModel.availableSnoozeLeads(for: later, now: trayChecksNow), [5, 10, 15, 30, 60])
    }

    await test("testSnoozedMeetingHiddenUntilRevealThenShows") {
        let meeting = trayChecksEvent("Standup", startMin: 60, endMin: 90)
        let snoozes = [meeting.schedulerKey: 10]
        // Before reveal (start minus 10 min) it is out of the menu bar.
        try expect(TrayModel.isMenuBarSnoozed(event: meeting, snoozes: snoozes, now: trayChecksNow))
        try expect(TrayModel.menuBarEvents([meeting], skipped: [], snoozes: snoozes,
                                           now: trayChecksNow).isEmpty)
        let hidden = TrayModel.state(
            events: TrayModel.menuBarEvents([meeting], skipped: [], snoozes: snoozes, now: trayChecksNow),
            now: trayChecksNow, leadMinutes: 1440)
        try expectEqual(hidden.title, "")
        try expect(!hidden.showsMeeting)

        // At start minus 9 minutes the snooze is spent and it is back.
        let afterReveal = trayChecksNow.addingTimeInterval(51 * 60)
        try expect(!TrayModel.isMenuBarSnoozed(event: meeting, snoozes: snoozes, now: afterReveal))
        let shown = TrayModel.state(
            events: TrayModel.menuBarEvents([meeting], skipped: [], snoozes: snoozes, now: afterReveal),
            now: afterReveal, leadMinutes: 1440)
        try expect(shown.title.hasPrefix("Standup"))
        try expect(shown.showsMeeting)
    }

    await test("testSnoozedMeetingLetsTheNextOneTakeOver") {
        let first = trayChecksEvent("First", startMin: 20, endMin: 40)
        let second = trayChecksEvent("Second", startMin: 45, endMin: 75)
        let events = TrayModel.menuBarEvents([first, second], skipped: [],
                                             snoozes: [first.schedulerKey: 5], now: trayChecksNow)
        let state = TrayModel.state(events: events, now: trayChecksNow, leadMinutes: 1440)
        try expect(state.title.hasPrefix("Second"))
        try expect(state.showsMeeting)
        // Narrow window and nothing else eligible: icon only.
        let iconOnly = TrayModel.state(
            events: TrayModel.menuBarEvents([first], skipped: [],
                                            snoozes: [first.schedulerKey: 5], now: trayChecksNow),
            now: trayChecksNow, leadMinutes: 60)
        try expectEqual(iconOnly.title, "")
        try expect(!iconOnly.showsMeeting)
    }

    await test("testSkipAndSnoozeFilteringCompose") {
        let skippedMeeting = trayChecksEvent("Skipped", startMin: 10, endMin: 40)
        let snoozedMeeting = trayChecksEvent("Snoozed", startMin: 20, endMin: 50)
        let plain = trayChecksEvent("Plain", startMin: 30, endMin: 60)
        let out = TrayModel.menuBarEvents([skippedMeeting, snoozedMeeting, plain],
                                          skipped: [skippedMeeting.schedulerKey],
                                          snoozes: [snoozedMeeting.schedulerKey: 5],
                                          now: trayChecksNow)
        try expectEqual(out.map(\.title), ["Plain"])
    }

    await test("testStaleSnoozeKeysDroppedOnceSpentOrGone") {
        let live = trayChecksEvent("Live", startMin: 60, endMin: 90)
        let spent = trayChecksEvent("Spent", startMin: 3, endMin: 40)
        let snoozes = [live.schedulerKey: 10, spent.schedulerKey: 10, "gone::key": 5]
        let stale = TrayModel.staleMenuBarSnoozeKeys(snoozes, events: [live, spent], now: trayChecksNow)
        try expectEqual(stale, Set([spent.schedulerKey, "gone::key"]))
    }

    await test("testMenuBarSnoozeLeavesAlertPlanningAlone") {
        // The snooze is a menu bar surface only: AlertPlanner never sees it.
        let meeting = trayChecksEvent("Standup", startMin: 60, endMin: 90)
        var settings = AppSettings.defaults
        settings.menuBarSnoozes = [meeting.schedulerKey: 10]
        let plans = AlertPlanner.plan(events: [meeting], settings: settings, now: trayChecksNow,
                                      fired: [], snoozedKeys: [])
        try expectEqual(Set(plans.map(\.leadMinutes)), Set(settings.alertLeadTimes))
    }
}

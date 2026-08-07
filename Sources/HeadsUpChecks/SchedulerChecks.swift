@testable import HeadsUpKit
import Foundation

// AlertPlanner is pure, so these checks exercise it directly with no timers.
// Scheduler's timer-driven behaviour (poll loop, armed alerts, snooze
// re-show) is not exercised here: the checks runner has no pumped run loop,
// so Timer callbacks never fire in this process. Only the pure planner is
// verified by check.

private let schedulerChecksNow = Date(timeIntervalSince1970: 1_800_000_000)

private func schedulerChecksEvent(_ id: String, startsInMinutes: Int, allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, title: id,
                  start: schedulerChecksNow.addingTimeInterval(Double(startsInMinutes) * 60),
                  end: schedulerChecksNow.addingTimeInterval(Double(startsInMinutes + 30) * 60),
                  allDay: allDay, location: nil, meetingUrl: nil, meetingProvider: nil,
                  accountEmail: nil, calendarName: nil, htmlLink: nil)
}

private var schedulerChecksSettings: AppSettings {
    var s = AppSettings.defaults
    s.alertLeadTimes = [30, 5]
    return s
}

func schedulerTests() async {
    suite("SchedulerTests")

    await test("testPlansBothLeadTimes") {
        let plans = AlertPlanner.plan(events: [schedulerChecksEvent("e", startsInMinutes: 60)],
                                      settings: schedulerChecksSettings, now: schedulerChecksNow,
                                      fired: [], snoozedKeys: [])
        try expectEqual(plans.count, 2)
        try expectEqual(Set(plans.map(\.leadMinutes)), Set([30, 5]))
        try expectEqual(plans.first { $0.leadMinutes == 30 }?.fireAt,
                        schedulerChecksNow.addingTimeInterval(30 * 60))
    }

    await test("testIdenticalLeadTimesDeduped") {
        var s = schedulerChecksSettings
        s.alertLeadTimes = [5, 5]
        let plans = AlertPlanner.plan(events: [schedulerChecksEvent("e", startsInMinutes: 60)],
                                      settings: s, now: schedulerChecksNow, fired: [], snoozedKeys: [])
        try expectEqual(plans.count, 1)
    }

    await test("testSkipsAllDayStartedSnoozedFiredAndDisabled") {
        let started = schedulerChecksEvent("started", startsInMinutes: -1)
        let allDay = schedulerChecksEvent("allday", startsInMinutes: 60, allDay: true)
        let snoozed = schedulerChecksEvent("snoozed", startsInMinutes: 60)
        let firedEvent = schedulerChecksEvent("fired", startsInMinutes: 60)
        let firedKey = PlannedFiring(event: firedEvent, leadMinutes: 30,
                                     fireAt: schedulerChecksNow).timerKey
        let plans = AlertPlanner.plan(
            events: [started, allDay, snoozed, firedEvent],
            settings: schedulerChecksSettings, now: schedulerChecksNow,
            fired: [firedKey],
            snoozedKeys: [snoozed.schedulerKey])
        try expect(!plans.contains { $0.event.id == "started" })
        try expect(!plans.contains { $0.event.id == "allday" })
        try expect(!plans.contains { $0.event.id == "snoozed" })
        // fired: 30-min key consumed, 5-min plan remains
        try expectEqual(plans.filter { $0.event.id == "fired" }.map(\.leadMinutes), [5])

        var off = schedulerChecksSettings
        off.alertsEnabled = false
        try expect(AlertPlanner.plan(events: [schedulerChecksEvent("e", startsInMinutes: 60)],
                                     settings: off, now: schedulerChecksNow, fired: [], snoozedKeys: []).isEmpty)
    }

    await test("testInsideLeadWindowFiresImmediately") {
        // Event in 10 minutes: the 30-min alert is already due (fireAt in the past).
        let plans = AlertPlanner.plan(events: [schedulerChecksEvent("e", startsInMinutes: 10)],
                                      settings: schedulerChecksSettings, now: schedulerChecksNow,
                                      fired: [], snoozedKeys: [])
        let lead30 = plans.first { $0.leadMinutes == 30 }
        try expectNotNil(lead30)
        try expect(lead30!.fireAt <= schedulerChecksNow)
    }

    await test("testDismissedEventNeverPlansAgain") {
        // A user-dismissed event gets NO further alerts for any lead time,
        // unlike a fired key, which only consumes one lead time.
        let event = schedulerChecksEvent("dismissed", startsInMinutes: 60)
        let plans = AlertPlanner.plan(events: [event],
                                      settings: schedulerChecksSettings, now: schedulerChecksNow,
                                      fired: [], snoozedKeys: [],
                                      dismissedKeys: [event.schedulerKey])
        try expect(plans.isEmpty)
        // Other events are unaffected by someone else's dismissal.
        let other = schedulerChecksEvent("other", startsInMinutes: 60)
        let otherPlans = AlertPlanner.plan(events: [other],
                                           settings: schedulerChecksSettings, now: schedulerChecksNow,
                                           fired: [], snoozedKeys: [],
                                           dismissedKeys: [event.schedulerKey])
        try expectEqual(otherPlans.count, 2)
    }
}

@testable import HeadsUpKit
import Foundation

// The gate is pure, so the timing rule is checked directly with fixed dates:
// no windows, no run loop, no real keystrokes. The controller wiring around
// it (recording shownAt per show, swallowing the event) is not exercised
// here, since it needs a live NSApplication.

private let escapeGateShownAt = Date(timeIntervalSince1970: 1_800_000_000)

func alertEscapeGateTests() async {
    suite("AlertEscapeGateTests")

    await test("testEscapeRightAfterShowIsIgnored") {
        // The reported case: the alert appeared and grabbed key status while
        // the user was already pressing Escape in another app.
        try expect(!AlertEscapeGate.shouldDismiss(
            shownAt: escapeGateShownAt,
            now: escapeGateShownAt.addingTimeInterval(0.2)))
    }

    await test("testEscapeAtGraceBoundaryDismisses") {
        // Exactly at the boundary counts as deliberate, so the grace period
        // never grows by a rounding accident.
        try expect(AlertEscapeGate.shouldDismiss(
            shownAt: escapeGateShownAt,
            now: escapeGateShownAt.addingTimeInterval(AlertEscapeGate.grace)))
        try expect(AlertEscapeGate.shouldDismiss(
            shownAt: escapeGateShownAt,
            now: escapeGateShownAt.addingTimeInterval(1.5)))
    }

    await test("testEscapeWellAfterShowDismisses") {
        try expect(AlertEscapeGate.shouldDismiss(
            shownAt: escapeGateShownAt,
            now: escapeGateShownAt.addingTimeInterval(3)))
    }
}

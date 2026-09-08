@testable import HeadsUpKit
import Foundation

func appSettingsTests() async {
    suite("AppSettingsTests")

    await test("testDefaults") {
        let s = AppSettings.defaults
        try expectEqual(s.alertLeadTimes, [30, 5])
        try expectEqual(s.snoozeDurations, [1, 5])
        try expect(s.alertsEnabled)
        try expectEqual(s.disabledCalendars, [])
        try expect(s.menuBarCalendarEnabled)
        try expectEqual(s.alertBackground, .solid)
        try expectEqual(s.appearance, .system)
        try expectEqual(s.eventOpenTarget, .googleWeb)
        try expectEqual(s.skippedEvents, [])
    }

    await test("testSanitizeRejectsDisallowedValuesPerIndex") {
        var s = AppSettings.defaults
        s.alertLeadTimes = [7, 10]      // 7 not allowed, 10 allowed
        s.snoozeDurations = [99, 2]     // 99 not allowed, 2 allowed
        s.disabledCalendars = ["a", "a", "b"]
        s.skippedEvents = ["k1", "k1", "k2"]
        let clean = AppSettings.sanitized(from: s)
        try expectEqual(clean.alertLeadTimes, [30, 10])   // falls back per index
        try expectEqual(clean.snoozeDurations, [1, 2])
        try expectEqual(Set(clean.disabledCalendars), Set(["a", "b"]))
        try expectEqual(clean.skippedEvents, ["k1", "k2"])
    }

    await test("testDecodeWithoutSkippedEventsFieldDefaultsEmpty") {
        // Settings persisted by builds predating skippedEvents must decode
        // to an empty skip list, not fail.
        let legacy = #"{"alertLeadTimes":[30,5],"alertsEnabled":true}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        try expectEqual(decoded.skippedEvents, [])
    }

    await test("testDecodeIgnoresRetiredBlurIntensityField") {
        // Settings files written by builds that still had the blur tint
        // slider carry the old key; it must be ignored, not fail decoding.
        let legacy = #"{"alertBackground":"blur","alertBlurIntensity":30}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        try expectEqual(decoded.alertBackground, .blur)
    }

    await test("testStoreRoundTripAndPatch") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headsup-test-\(UUID().uuidString)")
        let store = SettingsStore(directory: dir)
        try expectEqual(store.settings, AppSettings.defaults)

        let updated = store.update { $0.alertLeadTimes = [15, 5]; $0.alertsEnabled = false }
        try expectEqual(updated.alertLeadTimes, [15, 5])
        try expect(!updated.alertsEnabled)

        // A fresh store over the same directory reads what was persisted.
        let store2 = SettingsStore(directory: dir)
        try expectEqual(store2.settings.alertLeadTimes, [15, 5])
        try expect(!store2.settings.alertsEnabled)
    }

    await test("testStoreNotifiesObservers") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headsup-test-\(UUID().uuidString)")
        let store = SettingsStore(directory: dir)
        var seen: [AppSettings] = []
        _ = store.addObserver { seen.append($0) }
        _ = store.update { $0.alertsEnabled = false }
        try expectEqual(seen.count, 1)
        try expect(!seen[0].alertsEnabled)
    }

    await test("testAlertTitleFontDefaultsAndRoundtrip") {
        // Settings written by versions without the field decode to Syne.
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        try expectEqual(legacy.alertTitleFont, .syne)
        var s = AppSettings.defaults
        s.alertTitleFont = .dmSans
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        try expectEqual(round.alertTitleFont, .dmSans)
    }

    await test("testCorruptFileFallsBackToDefaults") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headsup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = SettingsStore(directory: dir)
        try expectEqual(store.settings, AppSettings.defaults)
    }
}

@testable import HeadsUpKit
import Foundation

func settingsViewTests() async {
    suite("SettingsViewTests")

    await test("testLeadTimeLabel") {
        try expectEqual(leadTimeLabel(0), "At event start")
        try expectEqual(leadTimeLabel(1), "1 minute before")
        try expectEqual(leadTimeLabel(5), "5 minutes before")
    }

    await test("testVersionLabel") {
        try expectEqual(SettingsModel.versionLabel(short: "1.5.0", build: "37"), "Heads Up 1.5.0 (37)")
        try expectEqual(SettingsModel.versionLabel(short: "1.5.0", build: nil), "Heads Up 1.5.0")
        try expectEqual(SettingsModel.versionLabel(short: nil, build: nil), "Heads Up (development build)")
        try expectEqual(SettingsModel.versionLabel(short: "", build: "3"), "Heads Up (development build)")
    }

    await test("testTruncatedMiddleShortValuePassesThrough") {
        try expectEqual(truncatedMiddle("short-id"), "short-id")
    }

    await test("testTruncatedMiddleLongValueTruncates") {
        let long = "123456789012-abcdefghijklmnopqrstuvwxyz.apps.googleusercontent.com"
        let result = truncatedMiddle(long, keep: 10)
        try expect(result.count < long.count)
        try expect(result.hasPrefix("1234567890"))
        try expect(result.hasSuffix(String(long.suffix(10))))
    }
}

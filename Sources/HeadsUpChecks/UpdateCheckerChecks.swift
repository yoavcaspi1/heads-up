@testable import HeadsUpKit
import Foundation

func updateCheckerTests() async {
    suite("UpdateCheckerTests")

    await test("testVersionParsing") {
        try expectEqual(AppVersion("1.2.3")?.components, [1, 2, 3])
        try expectEqual(AppVersion(" 1.1.0\n")?.components, [1, 1, 0])
        try expect(AppVersion("") == nil)
        try expect(AppVersion("abc") == nil)
        try expect(AppVersion("1.x.0") == nil)
        try expect(AppVersion("1.-2") == nil)
    }

    await test("testVersionOrdering") {
        try expect(AppVersion("1.0.0")! < AppVersion("1.1.0")!)
        try expect(AppVersion("1.1.0")! < AppVersion("1.1.1")!)
        try expect(AppVersion("1.9.0")! < AppVersion("1.10.0")!)   // numeric, not lexical
        try expect(AppVersion("1.1")! == AppVersion("1.1.0")!)     // missing component is 0
        try expect(!(AppVersion("2.0")! < AppVersion("1.9.9")!))
    }

    await test("testSourceDirectoryNilOutsideBundle") {
        // Running as a bare SPM executable there is no source_path.txt in
        // Bundle.main, so the updater must fall back rather than crash.
        try expect(UpdateChecker.sourceDirectory() == nil)
    }
}

@testable import HeadsUpKit

func smokeTests() async {
    suite("SmokeTests")

    await test("designSystemTokensResolve") {
        try expectEqual(YCDesignSystem.Spacing.md, 16)
        try expectEqual(YCDesignSystem.CornerRadius.medium, 8)
    }
}

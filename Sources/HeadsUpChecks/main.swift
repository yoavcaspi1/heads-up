import Foundation

// Standalone check runner, used in place of `swift test` so the suite runs
// on machines with only the Xcode Command Line Tools installed (no
// XCTest.framework, no swift-testing module). Run with `swift run HeadsUpChecks`.

await smokeTests()
await appSettingsTests()
await meetingLinkTests()
await notionCalendarLinkTests()
await eventNormalizationTests()
await secretStoreTests()
await googleCredentialsStoreTests()
await pkceTests()
await loopbackServerTests()
await oauthErrorTests()
await accountsRegistryTests()
await calendarClientTests()
await schedulerTests()
await trayModelTests()
await calendarListModelTests()
await settingsViewTests()
await alertBackdropTests()
await alertEscapeGateTests()
await setupWizardModelTests()

print("")
print("passed \(TestRun.passed), failed \(TestRun.failed)")
exit(TestRun.failed == 0 ? 0 : 1)

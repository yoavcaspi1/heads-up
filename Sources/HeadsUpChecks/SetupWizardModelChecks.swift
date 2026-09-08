@testable import HeadsUpKit
import Foundation

func setupWizardModelTests() async {
    suite("SetupWizardModelTests")

    func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wizard-\(UUID().uuidString).json")
    }

    await test("testStartsAtWelcomeAndWalksForward") {
        let model = SetupWizardModel(stateURL: tempStateURL(),
                                     saveCredentials: { _, _ in },
                                     credentialsConfigured: { false })
        try expectEqual(model.step, .welcome)
        try expect(model.canAdvance)
        model.advance()   // welcome -> createProject
        model.advance()   // -> enableAPI
        model.advance()   // -> consentScreen
        try expectEqual(model.step, .consentScreen)
        model.goBack()
        try expectEqual(model.step, .enableAPI)
    }

    await test("testCreateClientGatesOnValidCredentials") {
        let model = SetupWizardModel(stateURL: tempStateURL(),
                                     saveCredentials: { _, _ in },
                                     credentialsConfigured: { false })
        model.advance(); model.advance(); model.advance(); model.advance()
        try expectEqual(model.step, .createClient)
        try expect(!model.canAdvance)
        model.clientId = "12345-abc.apps.googleusercontent.com"
        model.clientSecret = "GOCSPX-something"
        try expect(model.canAdvance)
    }

    await test("testAdvancePastCreateClientSavesTrimmedCredentials") {
        var captured: [(String, String)] = []
        let model = SetupWizardModel(
            stateURL: tempStateURL(),
            saveCredentials: { captured.append(($0, $1)) },
            credentialsConfigured: { false })
        model.advance(); model.advance(); model.advance(); model.advance()
        model.clientId = "  12345-abc.apps.googleusercontent.com \n"
        model.clientSecret = " GOCSPX-something "
        model.advance()
        try expectEqual(model.step, .signIn)
        try expectEqual(captured.count, 1)
        try expectEqual(captured.first?.0, "12345-abc.apps.googleusercontent.com")
        try expectEqual(captured.first?.1, "GOCSPX-something")
    }

    await test("testSignInGateAndSkip") {
        let model = SetupWizardModel(stateURL: tempStateURL(),
                                     saveCredentials: { _, _ in },
                                     credentialsConfigured: { false })
        model.advance(); model.advance(); model.advance(); model.advance()
        model.clientId = "1.apps.googleusercontent.com"
        model.clientSecret = "s"
        model.advance()
        try expectEqual(model.step, .signIn)
        try expect(!model.canAdvance)          // no account yet
        model.markSignedIn()
        try expect(model.signedIn)
        try expect(model.canAdvance)
        model.advance()
        try expectEqual(model.step, .done)

        // Skip path
        let model2 = SetupWizardModel(stateURL: tempStateURL(),
                                      saveCredentials: { _, _ in },
                                      credentialsConfigured: { false })
        model2.advance(); model2.advance(); model2.advance(); model2.advance()
        model2.clientId = "1.apps.googleusercontent.com"
        model2.clientSecret = "s"
        model2.advance()
        model2.skipSignIn()
        try expectEqual(model2.step, .done)
    }

    await test("testClientIdValidation") {
        try expect(SetupWizardModel.isValidClientId("12345-abc.apps.googleusercontent.com"))
        try expect(SetupWizardModel.isValidClientId(" 1.apps.googleusercontent.com "))
        try expect(!SetupWizardModel.isValidClientId(""))
        try expect(!SetupWizardModel.isValidClientId(".apps.googleusercontent.com"))
        try expect(!SetupWizardModel.isValidClientId("12345-abc.example.com"))
        try expect(SetupWizardModel.isValidClientSecret("GOCSPX-x"))
        try expect(!SetupWizardModel.isValidClientSecret("   "))
    }

    await test("testStatePersistsAndRestores") {
        let url = tempStateURL()
        let model = SetupWizardModel(stateURL: url,
                                     saveCredentials: { _, _ in },
                                     credentialsConfigured: { false })
        model.advance(); model.advance()
        try expectEqual(model.step, .enableAPI)
        let restored = SetupWizardModel(stateURL: url,
                                        saveCredentials: { _, _ in },
                                        credentialsConfigured: { false })
        try expectEqual(restored.step, .enableAPI)
    }

    await test("testCorruptStateFileFallsBackToWelcome") {
        let url = tempStateURL()
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let model = SetupWizardModel(stateURL: url,
                                     saveCredentials: { _, _ in },
                                     credentialsConfigured: { false })
        try expectEqual(model.step, .welcome)
    }

    await test("testShouldAutoShow") {
        // Fresh install with a bundled client: configured but no account yet.
        try expect(SetupWizardModel.shouldAutoShow(credentialsConfigured: true, hasAccounts: false, finishedBefore: false))
        // Fresh install without one.
        try expect(SetupWizardModel.shouldAutoShow(credentialsConfigured: false, hasAccounts: false, finishedBefore: false))
        // Fully set up.
        try expect(!SetupWizardModel.shouldAutoShow(credentialsConfigured: true, hasAccounts: true, finishedBefore: false))
        // Skipped sign-in earlier: never nag again.
        try expect(!SetupWizardModel.shouldAutoShow(credentialsConfigured: true, hasAccounts: false, finishedBefore: true))
    }

    await test("testBundledClientFlowIsWelcomeSignInDone") {
        let model = SetupWizardModel(stateURL: tempStateURL(),
                                     saveCredentials: { _, _ in },
                                     credentialsConfigured: { true },
                                     bundledClientAvailable: true)
        try expectEqual(model.steps, [.welcome, .signIn, .done])
        try expectEqual(model.stepCount, 2)
        try expectEqual(model.stepNumber, 1)
        model.advance()
        try expectEqual(model.step, .signIn)
        try expectEqual(model.stepNumber, 2)
        try expect(!model.canAdvance)
        model.goBack()
        try expectEqual(model.step, .welcome)
        model.advance()
        model.markSignedIn()
        model.advance()
        try expectEqual(model.step, .done)
        try expect(model.finished)
        try expectEqual(model.stepNumber, 2)
    }

    await test("testFullFlowStepNumbering") {
        let model = SetupWizardModel(stateURL: tempStateURL(),
                                     saveCredentials: { _, _ in },
                                     credentialsConfigured: { false })
        try expectEqual(model.stepCount, 6)
        model.advance(); model.advance(); model.advance(); model.advance()
        try expectEqual(model.step, .createClient)
        try expectEqual(model.stepNumber, 5)
    }

    await test("testPersistedConsoleStepRestartsInBundledFlow") {
        // State saved by a build without a bundled client, mid-console.
        let url = tempStateURL()
        let old = SetupWizardModel(stateURL: url, saveCredentials: { _, _ in }, credentialsConfigured: { false })
        old.advance(); old.advance()
        try expectEqual(old.step, .enableAPI)
        let bundled = SetupWizardModel(stateURL: url, saveCredentials: { _, _ in },
                                       credentialsConfigured: { true }, bundledClientAvailable: true)
        try expectEqual(bundled.step, .welcome)
    }

    await test("testPageURLs") {
        try expectEqual(SetupWizardModel.pageURL(for: .createProject)?.absoluteString,
                        "https://console.cloud.google.com/projectcreate")
        try expectEqual(SetupWizardModel.pageURL(for: .enableAPI)?.absoluteString,
                        "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")
        try expectEqual(SetupWizardModel.pageURL(for: .consentScreen)?.absoluteString,
                        "https://console.cloud.google.com/apis/credentials/consent")
        try expectEqual(SetupWizardModel.pageURL(for: .createClient)?.absoluteString,
                        "https://console.cloud.google.com/apis/credentials/oauthclient")
        try expectNil(SetupWizardModel.pageURL(for: .welcome))
        try expectNil(SetupWizardModel.pageURL(for: .signIn))
        try expectNil(SetupWizardModel.pageURL(for: .done))
    }
}

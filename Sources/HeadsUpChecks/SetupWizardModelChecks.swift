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
        try expect(SetupWizardModel.shouldAutoShow(credentialsConfigured: false))
        try expect(!SetupWizardModel.shouldAutoShow(credentialsConfigured: true))
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

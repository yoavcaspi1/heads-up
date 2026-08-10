# Friend Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Friends install Heads Up by downloading a DMG from GitHub Releases; a first-run wizard guides the one-time Google OAuth setup; installed copies auto-update via Sparkle when Yoav publishes a release.

**Architecture:** A pure-logic `SetupWizardModel` (checked by HeadsUpChecks) drives a SwiftUI wizard window auto-shown until Google client credentials exist. The git-pull updater (`UpdateChecker`) is deleted and replaced by Sparkle 2 (first SPM dependency), fed by `appcast.xml` on `main` with zips on GitHub Releases. `build_app.sh` gains env-var overrides (identity, universal, hardened) and embeds Sparkle; a new `release.sh` produces the signed/notarized DMG + zip and publishes.

**Tech Stack:** Swift 5.10 SPM (no Xcode project), AppKit + SwiftUI, Sparkle 2, bash, `gh` CLI, `notarytool`.

## Global Constraints

- Platform floor: macOS 14.0 (`Package.swift` platforms, `LSMinimumSystemVersion`).
- Checks must stay green after every task: `swift run HeadsUpChecks` → `passed N, failed 0`.
- Test style: hand-rolled TestKit (`suite("Name")`, `await test("name") { try expect(...) }`), registered in `Sources/HeadsUpChecks/main.swift`. No XCTest.
- The repo is PUBLIC. Never commit: private keys, notary credentials, real emails, machine paths (`/Users/...`, `CBD Dropbox`). The Sparkle PUBLIC key is safe to commit.
- UI copy: no em dashes; use YCDesignSystem tokens for fonts/colors/spacing.
- Bundle ID `com.yoavcaspi.headsup`; app display name "Heads Up"; version source of truth is the `VERSION` file (currently 1.2.0; first Sparkle release will be 1.3.0, NOT part of this plan).
- Do not install over the running app during verification: always `./build_app.sh --no-install`.
- Never push `backup/*` branches. Do not push `main` without Yoav's explicit go-ahead (final task pauses for it).
- Commit after every task with the exact message given.

---

### Task 1: SetupWizardModel (pure logic) + checks

**Files:**
- Create: `Sources/HeadsUpKit/Setup/SetupWizardModel.swift`
- Create: `Sources/HeadsUpChecks/SetupWizardModelChecks.swift`
- Modify: `Sources/HeadsUpChecks/main.swift` (register suite)

**Interfaces:**
- Consumes: nothing new (Foundation + Combine only; credential I/O injected as closures).
- Produces (used by Task 2):
  - `enum SetupStep: Int, CaseIterable, Codable` cases `welcome, createProject, enableAPI, consentScreen, createClient, signIn, done`
  - `final class SetupWizardModel: ObservableObject` with `init(stateURL: URL, saveCredentials: @escaping (String, String) -> Void, credentialsConfigured: @escaping () -> Bool)`, `@Published private(set) var step`, `@Published var clientId/clientSecret: String`, `@Published private(set) var signedIn: Bool`, `@Published var errorMessage: String?`, `var canAdvance: Bool`, `func advance()`, `func goBack()`, `func markSignedIn()`, `func skipSignIn()`, `static func isValidClientId(_:) -> Bool`, `static func isValidClientSecret(_:) -> Bool`, `static func shouldAutoShow(credentialsConfigured: Bool) -> Bool`, `static func pageURL(for: SetupStep) -> URL?`

- [ ] **Step 1: Write the failing checks**

Create `Sources/HeadsUpChecks/SetupWizardModelChecks.swift`:

```swift
@testable import HeadsUpKit
import Foundation

func setupWizardModelTests() async {
    suite("SetupWizardModelTests")

    func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wizard-\(UUID().uuidString).json")
    }
    func makeModel(saved: inout [(String, String)]) -> SetupWizardModel {
        var captured: [(String, String)] = []
        let model = SetupWizardModel(
            stateURL: tempStateURL(),
            saveCredentials: { captured.append(($0, $1)) },
            credentialsConfigured: { false })
        saved = captured
        return model
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
```

In `Sources/HeadsUpChecks/main.swift`, add after `await settingsViewTests()`:

```swift
await setupWizardModelTests()
```

- [ ] **Step 2: Run checks to verify they fail to compile**

Run: `swift run HeadsUpChecks`
Expected: compile error, `cannot find 'SetupWizardModel' in scope`

- [ ] **Step 3: Implement the model**

Create `Sources/HeadsUpKit/Setup/SetupWizardModel.swift`:

```swift
import Foundation
import Combine

/// Ordered wizard pages. Raw values are persisted; append-only.
public enum SetupStep: Int, CaseIterable, Codable {
    case welcome = 0
    case createProject
    case enableAPI
    case consentScreen
    case createClient
    case signIn
    case done
}

/// Pure state machine behind the first-run setup wizard. Owns step
/// navigation, client-credential validation, and resume-where-you-left-off
/// persistence. All credential and account I/O is injected so checks can
/// exercise every path without a Keychain or network.
public final class SetupWizardModel: ObservableObject {
    @Published public private(set) var step: SetupStep
    @Published public var clientId: String = ""
    @Published public var clientSecret: String = ""
    @Published public private(set) var signedIn: Bool = false
    @Published public var errorMessage: String?

    private let stateURL: URL
    private let saveCredentials: (String, String) -> Void
    private let credentialsConfigured: () -> Bool

    private struct PersistedState: Codable { var step: Int }

    public init(stateURL: URL,
                saveCredentials: @escaping (String, String) -> Void,
                credentialsConfigured: @escaping () -> Bool) {
        self.stateURL = stateURL
        self.saveCredentials = saveCredentials
        self.credentialsConfigured = credentialsConfigured
        if let data = try? Data(contentsOf: stateURL),
           let persisted = try? JSONDecoder().decode(PersistedState.self, from: data),
           let restored = SetupStep(rawValue: persisted.step) {
            step = restored
        } else {
            step = .welcome
        }
    }

    /// The wizard self-opens only until client credentials exist; after
    /// that the tray menu's "Setup Guide" is the way back in.
    public static func shouldAutoShow(credentialsConfigured: Bool) -> Bool {
        !credentialsConfigured
    }

    public static func isValidClientId(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        return value.hasSuffix(suffix) && value.count > suffix.count
    }

    public static func isValidClientSecret(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The exact Google Cloud console page each guided step acts on.
    public static func pageURL(for step: SetupStep) -> URL? {
        switch step {
        case .createProject:
            return URL(string: "https://console.cloud.google.com/projectcreate")
        case .enableAPI:
            return URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")
        case .consentScreen:
            return URL(string: "https://console.cloud.google.com/apis/credentials/consent")
        case .createClient:
            return URL(string: "https://console.cloud.google.com/apis/credentials/oauthclient")
        case .welcome, .signIn, .done:
            return nil
        }
    }

    public var canAdvance: Bool {
        switch step {
        case .welcome, .createProject, .enableAPI, .consentScreen:
            return true
        case .createClient:
            return Self.isValidClientId(clientId) && Self.isValidClientSecret(clientSecret)
        case .signIn:
            return signedIn
        case .done:
            return false
        }
    }

    public func advance() {
        guard canAdvance, let next = SetupStep(rawValue: step.rawValue + 1) else { return }
        if step == .createClient {
            saveCredentials(
                clientId.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        errorMessage = nil
        step = next
        persist()
    }

    public func goBack() {
        guard let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
        errorMessage = nil
        step = previous
        persist()
    }

    public func markSignedIn() {
        signedIn = true
        errorMessage = nil
    }

    /// "Skip for now" on the sign-in page; Settings can finish the job later.
    public func skipSignIn() {
        guard step == .signIn else { return }
        step = .done
        persist()
    }

    private func persist() {
        let state = PersistedState(step: step.rawValue)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}
```

- [ ] **Step 4: Run checks to verify they pass**

Run: `swift run HeadsUpChecks`
Expected: `passed N, failed 0` where N = previous total + 9

- [ ] **Step 5: Commit**

```bash
git add Sources/HeadsUpKit/Setup/SetupWizardModel.swift Sources/HeadsUpChecks/SetupWizardModelChecks.swift Sources/HeadsUpChecks/main.swift
git commit -m "feat: setup wizard state machine with persistence and validation"
```

---

### Task 2: Wizard window (SwiftUI view + controller) and app wiring

**Files:**
- Create: `Sources/HeadsUpKit/Views/SetupWizardView.swift`
- Create: `Sources/HeadsUpKit/Windows/SetupWizardWindowController.swift`
- Modify: `Sources/HeadsUpKit/AppDelegate.swift` (own the controller, auto-show, debug flag)
- Modify: `Sources/HeadsUpKit/Tray/TrayController.swift` (add "Setup Guide…" menu item)

**Interfaces:**
- Consumes (Task 1): `SetupWizardModel`, `SetupStep`, `SetupWizardModel.pageURL(for:)`, `shouldAutoShow(credentialsConfigured:)`.
- Consumes (existing): `GoogleCredentialsStore` (`isConfigured`, `save(clientId:clientSecret:)`), `GoogleAccountsRegistry.addAccount()` (async throws, as used in `SettingsModel.addAccount()` at `Sources/HeadsUpKit/Views/SettingsView.swift:180-185`), `SettingsWindowController` hide-on-close pattern.
- Produces: `SetupWizardWindowController` with `init(credentials:registry:)` and `func show()`; `TrayController.onOpenSetupGuide: (() -> Void)?`.

- [ ] **Step 1: Create the view**

Create `Sources/HeadsUpKit/Views/SetupWizardView.swift`. Copy per step lives here; look at `SettingsView.swift` first and reuse its font/color token style (`YCDesignSystem.Typography...`, `YCDesignSystem.Color...`) for exact modifier names rather than inventing new ones.

```swift
import SwiftUI
import AppKit

/// First-run guided setup. Each page: title, short instructions, one
/// action (open the exact Google page / paste fields / sign in), Back-Next.
struct SetupWizardView: View {
    @ObservedObject var model: SetupWizardModel
    /// Runs the OAuth browser flow; throws on failure or cancel.
    let signIn: () async throws -> Void
    let onFinished: () -> Void

    @State private var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            progressHeader
            stepBody
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 520, height: 480)
    }

    private var progressHeader: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.allCases.filter { $0 != .done }, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= model.step.rawValue
                          ? Color(nsColor: YCDesignSystemNSColor.harbor)
                          : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Text("Step \(min(model.step.rawValue + 1, 6)) of 6")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .welcome:
            page(title: "Welcome to Heads Up",
                 lines: [
                    "Heads Up watches your Google Calendar and puts a full-screen alert in front of you before each meeting.",
                    "One-time setup: connect the app to your own Google account. It takes about 10 minutes and this guide walks you through every click.",
                    "You will create a free Google \"project\" that belongs to you, so your calendar data never goes through anyone else's account.",
                 ])
        case .createProject:
            page(title: "1. Create a Google Cloud project",
                 lines: [
                    "Click the button below. Sign in with your Google account if asked.",
                    "Give the project any name (for example \"Heads Up\"), then press Create.",
                    "Wait for the notification that the project is ready, then come back here.",
                 ],
                 linkTitle: "Open Google Cloud - New Project")
        case .enableAPI:
            page(title: "2. Turn on the Calendar API",
                 lines: [
                    "Click the button below. Make sure your new project is selected in the top bar.",
                    "Press the blue Enable button.",
                 ],
                 linkTitle: "Open the Calendar API page")
        case .consentScreen:
            page(title: "3. Set up the consent screen",
                 lines: [
                    "Click the button below and choose External, then Create.",
                    "Fill only the required fields: app name (Heads Up), your email as user support email and developer contact. Save through the remaining screens.",
                    "Important: on the consent screen overview, press \"Publish app\". If you leave it in Testing mode, Google disconnects the app every 7 days and alerts silently stop.",
                 ],
                 linkTitle: "Open the consent screen page")
        case .createClient:
            VStack(alignment: .leading, spacing: 12) {
                page(title: "4. Create the app's key",
                     lines: [
                        "Click the button below. Choose \"Desktop app\" as the type, any name, then Create.",
                        "Google shows a Client ID and a Client secret. Copy each one into the fields here.",
                     ],
                     linkTitle: "Open the Create OAuth client page")
                TextField("Client ID (ends in .apps.googleusercontent.com)", text: $model.clientId)
                    .textFieldStyle(.roundedBorder)
                TextField("Client secret", text: $model.clientSecret)
                    .textFieldStyle(.roundedBorder)
                if !model.clientId.isEmpty && !SetupWizardModel.isValidClientId(model.clientId) {
                    Text("That does not look like a client ID. It should end in .apps.googleusercontent.com.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        case .signIn:
            VStack(alignment: .leading, spacing: 12) {
                page(title: "5. Sign in with Google",
                     lines: [
                        "Press the button below. Your browser opens Google's sign-in page.",
                        "Google will warn that the app is not verified. That is expected: it is YOUR app, created minutes ago. Click \"Advanced\", then \"Go to Heads Up (unsafe)\", then allow calendar access.",
                     ])
                Button(signingIn ? "Waiting for Google…" : "Sign in with Google") {
                    signingIn = true
                    Task { @MainActor in
                        defer { signingIn = false }
                        do {
                            try await signIn()
                            model.markSignedIn()
                        } catch {
                            model.errorMessage = "Sign-in did not complete: \(error.localizedDescription)"
                        }
                    }
                }
                .disabled(signingIn)
                if model.signedIn {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if let message = model.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        case .done:
            page(title: "All set",
                 lines: [
                    "Heads Up now lives in your menu bar (look for the bell icon at the top right of the screen).",
                    "Left-click the bell for your meeting list, right-click for settings.",
                    "The app updates itself automatically when a new version is released. Nothing else to do.",
                 ])
        }
    }

    private func page(title: String, lines: [String], linkTitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            ForEach(lines, id: \.self) { line in
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
            if let linkTitle, let url = SetupWizardModel.pageURL(for: model.step) {
                Button(linkTitle) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.goBack() }
            }
            Spacer()
            if model.step == .signIn && !model.signedIn {
                Button("Skip for now") { model.skipSignIn() }
            }
            if model.step == .done {
                Button("Finish") { onFinished() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .welcome ? "Get started" : "Next") { model.advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance)
            }
        }
    }
}
```

NOTE for implementer: `YCDesignSystemNSColor` is `internal` in `TrayController.swift` and usable from the same module. If `SettingsView.swift` exposes proper SwiftUI design tokens (check first), use those instead of `Color(nsColor: YCDesignSystemNSColor.harbor)`.

- [ ] **Step 2: Create the window controller**

Create `Sources/HeadsUpKit/Windows/SetupWizardWindowController.swift`, modeled exactly on `SettingsWindowController` (hide on close, state lives in the model):

```swift
import AppKit
import SwiftUI

/// Owns the single Setup Guide window. Hide-on-close like Settings: the
/// wizard model (current step, pasted fields) survives show/hide cycles,
/// and its own JSON state file survives relaunches.
final class SetupWizardWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    let model: SetupWizardModel
    private let makeContent: () -> NSView

    init(credentials: GoogleCredentialsStore, registry: GoogleAccountsRegistry) {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("HeadsUp")
        try? FileManager.default.createDirectory(at: supportDir,
                                                 withIntermediateDirectories: true)
        let model = SetupWizardModel(
            stateURL: supportDir.appendingPathComponent("setup_wizard.json"),
            saveCredentials: { id, secret in
                credentials.save(clientId: id, clientSecret: secret)
            },
            credentialsConfigured: { credentials.isConfigured })
        self.model = model
        var closeWindow: (() -> Void)?
        self.makeContent = {
            NSHostingView(rootView: SetupWizardView(
                model: model,
                signIn: { _ = try await registry.addAccount() },
                onFinished: { closeWindow?() }))
        }
        super.init()
        closeWindow = { [weak self] in self?.window?.orderOut(nil) }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Heads Up Setup Guide"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = makeContent()
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
```

If `registry.addAccount()`'s signature differs (check `SettingsView.swift:180-185` and `GoogleAccountsRegistry.swift`), adapt the `signIn` closure to match; the wizard only needs "completed without throwing".

- [ ] **Step 3: Wire into AppDelegate and tray**

In `Sources/HeadsUpKit/AppDelegate.swift`:

Add property after `private var settingsWindow: SettingsWindowController!`:

```swift
    private var setupWizard: SetupWizardWindowController!
```

In `finishLaunching()`, after the `settingsWindow = ...` assignment block, add:

```swift
        setupWizard = SetupWizardWindowController(credentials: credentials, registry: registry)
        tray.onOpenSetupGuide = { [weak self] in self?.setupWizard?.show() }
        if SetupWizardModel.shouldAutoShow(credentialsConfigured: credentials.isConfigured)
            || ProcessInfo.processInfo.arguments.contains("--setup-wizard") {
            setupWizard.show()
        }
```

In `Sources/HeadsUpKit/Tray/TrayController.swift`:

Add after `var onRunUpdate: (() -> Void)?`:

```swift
    var onOpenSetupGuide: (() -> Void)?
```

In `showMenu()`, after the `menu.addItem(settings)` line, add:

```swift
        let guide = NSMenuItem(title: "Setup Guide…", action: #selector(openSetupGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
```

Add next to `@objc private func openSettings()`:

```swift
    @objc private func openSetupGuide() {
        onOpenSetupGuide?()
    }
```

- [ ] **Step 4: Build, run checks, and eyeball the wizard**

Run: `swift build && swift run HeadsUpChecks`
Expected: build succeeds, `passed N, failed 0` (same N as Task 1)

Run: `./build_app.sh --no-install` then
`"build/Heads Up.app/Contents/MacOS/HeadsUp" --setup-wizard` (foreground, kill with Ctrl+C after checking)
Expected: Setup Guide window opens on the welcome page; Next walks pages; the createClient page gates Next until both fields validate. Do NOT install; kill the process when done. If a screen recording or live call is in progress on this machine, defer this visual check.

- [ ] **Step 5: Commit**

```bash
git add Sources/HeadsUpKit/Views/SetupWizardView.swift Sources/HeadsUpKit/Windows/SetupWizardWindowController.swift Sources/HeadsUpKit/AppDelegate.swift Sources/HeadsUpKit/Tray/TrayController.swift
git commit -m "feat: first-run setup guide window with live Google walkthrough"
```

---

### Task 3: Remove git-pull updater, integrate Sparkle 2

**Files:**
- Delete: `Sources/HeadsUpKit/Services/UpdateChecker.swift`
- Delete: `Sources/HeadsUpChecks/UpdateCheckerChecks.swift`
- Modify: `Package.swift` (Sparkle dependency)
- Modify: `Sources/HeadsUpChecks/main.swift` (drop `updateCheckerTests()`)
- Modify: `Sources/HeadsUpKit/AppDelegate.swift` (swap updater)
- Modify: `Sources/HeadsUpKit/Tray/TrayController.swift` (swap menu item)
- Modify: `build_app.sh` (embed + sign Sparkle, new Info.plist keys, env overrides, drop source_path.txt)

**Interfaces:**
- Consumes: Sparkle product `Sparkle`, class `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)`, method `checkForUpdates(_:)`.
- Produces: `TrayController.onCheckForUpdates: (() -> Void)?`; `build_app.sh` env vars `HEADSUP_SIGN_IDENTITY`, `HEADSUP_UNIVERSAL`, `HEADSUP_HARDENED` (Task 4 consumes these); Info.plist keys `SUFeedURL`, `SUPublicEDKey` (from `sparkle_public_key.txt` when present), `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, `SUAutomaticallyUpdate`.

- [ ] **Step 1: Check nothing else uses the old updater's types**

Run: `grep -rn "AppVersion\|UpdateChecker" Sources/ --include=*.swift | grep -v "Sources/HeadsUpKit/Services/UpdateChecker.swift" | grep -v UpdateCheckerChecks`
Expected: only the `AppDelegate.swift` and `TrayController.swift` lines this task removes. If anything else appears, stop and resolve before deleting.

- [ ] **Step 2: Add Sparkle to Package.swift**

Replace the full `Package.swift` with:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HeadsUp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HeadsUp", targets: ["HeadsUp"])
    ],
    dependencies: [
        // Auto-updates for the downloadable build. The only dependency.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // All app code lives here so it can be depended on both by the
        // HeadsUp executable and by HeadsUpChecks (no XCTest.framework on
        // this machine, so checks run as a plain executable instead).
        .target(
            name: "HeadsUpKit",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/HeadsUpKit",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "HeadsUp",
            dependencies: ["HeadsUpKit"],
            path: "Sources/HeadsUp"
        ),
        .executableTarget(
            name: "HeadsUpChecks",
            dependencies: ["HeadsUpKit"],
            path: "Sources/HeadsUpChecks"
        )
    ]
)
```

Run: `swift build`
Expected: Sparkle resolves and the build succeeds (still with the old UpdateChecker present).

- [ ] **Step 3: Delete the old updater and swap in Sparkle**

```bash
git rm Sources/HeadsUpKit/Services/UpdateChecker.swift Sources/HeadsUpChecks/UpdateCheckerChecks.swift
```

In `Sources/HeadsUpChecks/main.swift`, delete the line `await updateCheckerTests()`.

In `Sources/HeadsUpKit/AppDelegate.swift`:
- Add `import Sparkle` under `import CoreText`.
- Replace `private var updateChecker: UpdateChecker!` with:

```swift
    // nil when running as a bare executable (swift run): Sparkle needs a
    // real bundle with SUFeedURL to start, and dev runs have neither.
    private var updaterController: SPUStandardUpdaterController?
```

- Replace this block in `applicationDidFinishLaunching`:

```swift
        updateChecker = UpdateChecker()
        tray.onRunUpdate = { [weak self] in self?.updateChecker.runSelfUpdate() }
        updateChecker.onUpdateAvailable = { [weak self] version in
            self?.tray.updateAvailable = version
        }
        updateChecker.start()
```

with:

```swift
        if Bundle.main.bundleIdentifier != nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        tray.onCheckForUpdates = { [weak self] in
            self?.updaterController?.checkForUpdates(nil)
        }
```

- In `applicationWillTerminate`, delete the `updateChecker?.stop()` line.

In `Sources/HeadsUpKit/Tray/TrayController.swift`:
- Delete `var updateAvailable: String?` and `var onRunUpdate: (() -> Void)?` and the `@objc private func runUpdate()` method.
- Add `var onCheckForUpdates: (() -> Void)?` (next to `onOpenSetupGuide`).
- In `showMenu()`, delete the whole `if let version = updateAvailable { ... }` block, and after the Setup Guide item add:

```swift
        let update = NSMenuItem(title: "Check for Updates…",
                                action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
```

- Add:

```swift
    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }
```

- [ ] **Step 4: Teach build_app.sh to embed and sign Sparkle**

In `build_app.sh`:

(a) Replace the identity constant block:

```bash
APP_NAME="HeadsUp"
APP_DISPLAY_NAME="Heads Up"
BUNDLE_ID="com.yoavcaspi.headsup"
SIGN_IDENTITY="HeadsUp Developer"
```

with:

```bash
APP_NAME="HeadsUp"
APP_DISPLAY_NAME="Heads Up"
BUNDLE_ID="com.yoavcaspi.headsup"
# release.sh overrides these three for distributable builds.
SIGN_IDENTITY="${HEADSUP_SIGN_IDENTITY:-HeadsUp Developer}"
UNIVERSAL="${HEADSUP_UNIVERSAL:-false}"
HARDENED="${HEADSUP_HARDENED:-false}"
```

(b) Replace the build + bin-path lines:

```bash
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)
```

with:

```bash
ARCH_FLAGS=()
if [[ "$UNIVERSAL" == "true" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
swift build -c "$CONFIG" --product "$APP_NAME" "${ARCH_FLAGS[@]}"

BIN_PATH=$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)
```

(c) Delete the two source_path lines (comment + `pwd > ...source_path.txt`): the git-pull updater they served is gone.

(d) After the AppIcon copy block, add:

```bash
# Embed Sparkle.framework (SPM ships it as a prebuilt universal artifact).
SPARKLE_FW=$(find .build/artifacts -type d -name "Sparkle.framework" \
    -not -path "*dSYM*" 2>/dev/null | head -1)
if [[ -z "$SPARKLE_FW" ]]; then
    echo "Error: Sparkle.framework not found under .build/artifacts (run swift build first)" >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"
# The executable references @rpath/Sparkle...; point rpath at Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
```

(e) In the Info.plist heredoc, after the `NSHighResolutionCapable` pair and before `</dict>`, add (note `$SPARKLE_KEY_XML` is substituted by bash):

```bash
SPARKLE_KEY_XML=""
if [[ -f "sparkle_public_key.txt" ]]; then
    SPARKLE_KEY_XML="    <key>SUPublicEDKey</key>
    <string>$(tr -d '[:space:]' < sparkle_public_key.txt)</string>"
else
    echo "Warning: sparkle_public_key.txt missing; update signatures will not verify" >&2
fi
```

and inside the plist:

```
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/yoavcaspi1/heads-up/main/appcast.xml</string>
$SPARKLE_KEY_XML
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>21600</integer>
    <key>SUAutomaticallyUpdate</key>
    <true/>
```

(the `SPARKLE_KEY_XML=` block must run BEFORE the `cat > ...Info.plist <<PLIST` heredoc).

(f) Replace the single `codesign -f -s "$SIGN_IDENTITY" -i "$BUNDLE_ID" "$APP_BUNDLE"` line with inside-out signing (required for notarization, harmless for dev builds):

```bash
SIGN_FLAGS=(-f -s "$SIGN_IDENTITY")
if [[ "$HARDENED" == "true" ]]; then
    SIGN_FLAGS+=(-o runtime --timestamp)
fi
FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
    for xpc in "$FW/Versions/B/XPCServices/"*.xpc; do
        [[ -d "$xpc" ]] && codesign "${SIGN_FLAGS[@]}" "$xpc"
    done
    [[ -f "$FW/Versions/B/Autoupdate" ]] && codesign "${SIGN_FLAGS[@]}" "$FW/Versions/B/Autoupdate"
    [[ -d "$FW/Versions/B/Updater.app" ]] && codesign "${SIGN_FLAGS[@]}" "$FW/Versions/B/Updater.app"
    codesign "${SIGN_FLAGS[@]}" "$FW"
fi
codesign "${SIGN_FLAGS[@]}" -i "$BUNDLE_ID" "$APP_BUNDLE"
```

- [ ] **Step 5: Verify build, checks, and a bundled launch**

Run: `swift run HeadsUpChecks`
Expected: `passed N, failed 0` where N = Task 2's N minus 3 (the three UpdateChecker checks are gone)

Run: `./build_app.sh --no-install`
Expected: bundle assembles, Sparkle embed message absent of errors, signing passes, warning about missing `sparkle_public_key.txt` is printed (expected until Yoav generates keys).

Run: `codesign --verify --deep --strict "build/Heads Up.app" && echo OK`
Expected: `OK`

Run: `"build/Heads Up.app/Contents/MacOS/HeadsUp" --setup-wizard` briefly
Expected: app launches with Sparkle loaded (no dyld crash - this is the rpath check), wizard opens. Kill it. Defer if a live call is in progress.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: replace git-pull updater with Sparkle 2 auto-updates"
```

---

### Task 4: release.sh + docs/RELEASING.md

**Files:**
- Create: `release.sh` (mode 755)
- Create: `docs/RELEASING.md`

**Interfaces:**
- Consumes: `build_app.sh` env overrides from Task 3 (`HEADSUP_SIGN_IDENTITY`, `HEADSUP_UNIVERSAL`, `HEADSUP_HARDENED`), `VERSION` file, `gh` CLI, `xcrun notarytool` profile named `headsup-notary`, Sparkle `sign_update` from `.build/artifacts`.
- Produces: `build/release/HeadsUp-X.Y.Z.dmg`, `build/release/HeadsUp-X.Y.Z.zip`, updated `appcast.xml` at repo root, git tag `vX.Y.Z`, GitHub Release. `--dry-run` produces artifacts only (self-signed, no notarize/tag/push/release).

- [ ] **Step 1: Write release.sh**

Create `release.sh`:

```bash
#!/usr/bin/env bash
# release.sh - Builds, signs, notarizes and publishes a Heads Up release.
#
# Normal flow (after one-time setup in docs/RELEASING.md):
#   1. Edit code, bump VERSION, commit everything.
#   2. ./release.sh
# Friends' installed copies pick the update up within 6 hours.
#
#   ./release.sh --dry-run   # build + package only: self-signed, no
#                            # notarization, no tag/push/GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

APP_DISPLAY_NAME="Heads Up"
VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v$VERSION"
OUT="build/release"
DMG="$OUT/HeadsUp-$VERSION.dmg"
ZIP="$OUT/HeadsUp-$VERSION.zip"
FEED_URL_BASE="https://github.com/yoavcaspi1/heads-up/releases/download/$TAG"

echo "==> Preflight ($VERSION, dry-run=$DRY_RUN)"
[[ -n "$(git status --porcelain)" ]] && { echo "Error: working tree not clean" >&2; exit 1; }
[[ "$(git branch --show-current)" != "main" ]] && { echo "Error: not on main" >&2; exit 1; }
if [[ "$DRY_RUN" == "false" ]]; then
    git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Error: tag $TAG already exists; bump VERSION" >&2; exit 1; }
    security find-identity -v -p codesigning | grep -q "Developer ID Application" \
        || { echo "Error: no Developer ID Application identity in Keychain" >&2; exit 1; }
    xcrun notarytool history --keychain-profile headsup-notary >/dev/null 2>&1 \
        || { echo "Error: notarytool profile 'headsup-notary' missing (see docs/RELEASING.md)" >&2; exit 1; }
    [[ -f "sparkle_public_key.txt" ]] || { echo "Error: sparkle_public_key.txt missing (see docs/RELEASING.md)" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "Error: gh not authenticated" >&2; exit 1; }
fi

echo "==> Building universal release bundle"
if [[ "$DRY_RUN" == "true" ]]; then
    HEADSUP_UNIVERSAL=true ./build_app.sh release --no-install
else
    DEV_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" \
        | head -1 | sed 's/.*"\(.*\)"/\1/')
    HEADSUP_SIGN_IDENTITY="$DEV_ID" HEADSUP_UNIVERSAL=true HEADSUP_HARDENED=true \
        ./build_app.sh release --no-install
fi
APP="build/$APP_DISPLAY_NAME.app"

echo "==> Scanning binary for personal paths"
if strings "$APP/Contents/MacOS/HeadsUp" | grep -E "/Users/|CBD Dropbox" ; then
    echo "Error: personal path leaked into the binary (see matches above)" >&2
    exit 1
fi
# Absolute rpaths from the build machine leak paths too; strip any.
otool -l "$APP/Contents/MacOS/HeadsUp" | grep -A2 LC_RPATH | grep " path /" \
    | awk '{print $2}' | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/HeadsUp"
    echo "    stripped rpath $rp"
done

if [[ "$DRY_RUN" == "false" ]]; then
    # rpath surgery invalidates the signature; re-sign the outer bundle.
    DEV_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" \
        | head -1 | sed 's/.*"\(.*\)"/\1/')
    codesign -f -o runtime --timestamp -s "$DEV_ID" "$APP"

    echo "==> Notarizing (this takes a few minutes)"
    NOTARIZE_ZIP=$(mktemp -d)/notarize.zip
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile headsup-notary --wait
    xcrun stapler staple "$APP"
fi

echo "==> Packaging DMG and zip"
rm -rf "$OUT"; mkdir -p "$OUT"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Signing the update zip (Sparkle EdDSA)"
SIGN_TOOL=$(find .build/artifacts -name sign_update -type f -perm +111 2>/dev/null | head -1)
[[ -z "$SIGN_TOOL" ]] && { echo "Error: sign_update tool not found under .build/artifacts" >&2; exit 1; }
ED_ATTRS=$("$SIGN_TOOL" "$ZIP")   # emits: sparkle:edSignature="..." length="..."

echo "==> Writing appcast.xml"
PUBDATE=$(date -R)
cat > appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Heads Up</title>
    <item>
      <title>Heads Up $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$FEED_URL_BASE/HeadsUp-$VERSION.zip" $ED_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST

if [[ "$DRY_RUN" == "true" ]]; then
    git checkout -- appcast.xml 2>/dev/null || rm -f appcast.xml
    echo "==> Dry run complete: $DMG / $ZIP (appcast not kept, nothing pushed)"
    exit 0
fi

echo "==> Publishing"
NOTES=$(git log --format='- %s' "$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)"..HEAD | head -20)
git add appcast.xml
git commit -m "release: Heads Up $VERSION"
git tag "$TAG"
git push origin main "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --title "Heads Up $VERSION" --notes "$NOTES"
echo "==> Done. Installed apps update within 6 hours."
```

Run: `chmod +x release.sh`

- [ ] **Step 2: Write docs/RELEASING.md**

Create `docs/RELEASING.md`:

```markdown
# Releasing Heads Up

Internal notes for the maintainer. Friends never need this file.

## One-time setup (after Apple Developer enrollment)

1. **Developer ID certificate.** In Xcode: Settings > Accounts > your
   Apple ID > Manage Certificates > + > Developer ID Application. Or via
   https://developer.apple.com/account/resources/certificates. Verify:
   `security find-identity -v -p codesigning | grep "Developer ID"`.
2. **Notarization credentials.** Create an app-specific password at
   https://account.apple.com (Sign-In and Security > App-Specific
   Passwords), then:
   `xcrun notarytool store-credentials headsup-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD`
3. **Sparkle signing keys.** Run
   `$(find .build/artifacts -name generate_keys -type f | head -1)`.
   The private key lands in the login Keychain (item "Private key for
   signing Sparkle updates" - NEVER export or commit it). Save the
   printed public key:
   `echo "PASTE_PUBLIC_KEY" > sparkle_public_key.txt` and commit that
   file (public keys are safe to publish).

## Every release

1. Make the changes; run `swift run HeadsUpChecks` until green.
2. Bump `VERSION` (semantic-ish: X.Y.Z), commit everything.
3. `./release.sh`

That builds a universal binary, signs with Developer ID, notarizes,
staples, packages `HeadsUp-X.Y.Z.dmg` (human download) and `.zip`
(Sparkle update), EdDSA-signs the zip, rewrites `appcast.xml`, commits
and tags, pushes, and creates the GitHub Release with both artifacts.

`./release.sh --dry-run` exercises everything local (self-signed, no
notarization, nothing pushed) - use it to test pipeline changes.

## First-run checklist for a new release machine

- Xcode Command Line Tools, `gh auth login`, plus the three setup steps
  above.
```

- [ ] **Step 3: Dry-run the pipeline**

Run: `./release.sh --dry-run`
Expected: preflight passes (clean tree required - commit first if needed), universal build, personal-path scan passes, DMG + zip land in `build/release/`, exits with "Dry run complete". If the strings scan fails, fix the leak before continuing (that is the scan doing its job).

Run: `lipo -archs "build/Heads Up.app/Contents/MacOS/HeadsUp"`
Expected: `x86_64 arm64`

- [ ] **Step 4: Commit**

```bash
git add release.sh docs/RELEASING.md
git commit -m "feat: signed+notarized release pipeline with Sparkle appcast"
```

---

### Task 5: README rewrite (download-first)

**Files:**
- Modify: `README.md`

**Interfaces:** none (docs only). Section names below are exact.

- [ ] **Step 1: Restructure**

Keep lines 1-13 (title + intro paragraphs) but replace the sentence about
the Electron original with a shorter pointer (the `GLAZE ORIGINAL/`
details move to the developer half). Then replace everything from
`## What it does` up to (not including) `## Where data lives` with:

```markdown
## What it does

- Signs in to one or more Google accounts (read-only calendar access).
- Shows the next/ongoing meeting in the menu bar with a live countdown.
- Fires a full-screen alert before each meeting, with snooze.
- Click the menu-bar bell for the day-by-day meeting list; right-click
  for settings, setup guide and updates.

## Install

1. Download `HeadsUp-<latest>.dmg` from the
   [Releases page](https://github.com/yoavcaspi1/heads-up/releases/latest).
2. Open it and drag **Heads Up** into the **Applications** folder.
3. Open Heads Up from Applications. Look for the bell icon in the menu
   bar, at the top right of the screen.

On first launch the app opens a **Setup Guide** that walks you through
connecting your Google Calendar. It takes about 10 minutes, once. The
guide is also available any time: right-click the bell icon and choose
"Setup Guide…".

Requires macOS 14 (Sonoma) or later. No Terminal, no other installs.

## Google setup, step by step

The in-app Setup Guide covers all of this interactively; this is the
same walkthrough in written form.

1. **Create a Google Cloud project** at
   https://console.cloud.google.com/projectcreate. Any name. Free.
2. **Enable the Calendar API**: open
   https://console.cloud.google.com/apis/library/calendar-json.googleapis.com
   with your project selected and press Enable.
3. **Configure the consent screen** at
   https://console.cloud.google.com/apis/credentials/consent: choose
   External, fill the required fields (app name, your email), save
   through the steps, then press **Publish app**. Publishing matters:
   in Testing mode Google disconnects the app every 7 days.
4. **Create credentials** at
   https://console.cloud.google.com/apis/credentials/oauthclient:
   type "Desktop app". Copy the Client ID and Client secret into the
   app's Setup Guide (or Settings > Google connection).
5. **Sign in** from the Setup Guide. Google shows an "unverified app"
   warning because the project is yours and brand new: click Advanced,
   then "Go to Heads Up (unsafe)", then allow calendar access. Repeat
   for each Google account you want alerts from.

## Updates

Heads Up updates itself: it checks for new releases every 6 hours,
downloads them automatically, and installs on relaunch. To check
manually, right-click the bell icon and choose "Check for Updates…".
```

- [ ] **Step 2: Move developer content behind a divider**

After the retained `## Where data lives` and `## Debug flags` sections, add a `## For developers` H2 and demote/move the remaining existing sections under it in this order, keeping their text otherwise intact: Building (SPM + Xcode + `build_app.sh`, including the one-time self-signed certificate section - clarify it is only for building from source, not for the downloaded app), Tests ("checks") - replacing the sentence promising "73 checks / passed 73, failed 0" with "All checks are expected to pass (`failed 0`) on a clean checkout", Relationship to `GLAZE ORIGINAL/`, Design system, Known notes. Delete the old `## Quick start` (superseded by `## Install`) and the old `## Updates` body (superseded above). Keep `## License` last, unchanged.

- [ ] **Step 3: Sanity-check the result**

Run: `grep -n "git clone\|build_app.sh\|73" README.md`
Expected: `git clone`/`build_app.sh` appear only under "For developers"; no bare "73" check-count promises remain.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: download-first README with written Google walkthrough"
```

---

### Task 6: Final verification and handoff

**Files:** none new.

- [ ] **Step 1: Full suite + fresh bundle**

Run: `swift run HeadsUpChecks && ./build_app.sh --no-install && codesign --verify --deep --strict "build/Heads Up.app" && echo ALL-OK`
Expected: `passed N, failed 0` then `ALL-OK`

- [ ] **Step 2: Update the daily log**

Append the completed work to `DAILY/<today>/<today>.md` per house format.

- [ ] **Step 3: STOP - confirm push with Yoav**

Pushing `main` publishes the new code, the spec and this plan on the
public repo. Safe with respect to installed 1.2.0 apps (VERSION is
untouched, so the old updater offers nothing), but it is an
externally-visible action: get an explicit go-ahead, then:

```bash
git push origin main
```

- [ ] **Step 4: Report what remains for Yoav**

Remaining outside this plan: Apple enrollment finishing; the three
one-time setup items in `docs/RELEASING.md`; bump VERSION to 1.3.0 and
run `./release.sh` for the first downloadable release; verify a
download-install on a second Mac; then share the repo link.
```

## Self-Review

- Spec coverage: wizard (Tasks 1-2), Sparkle + old-updater removal (Task 3), release pipeline + RELEASING.md (Task 4), README (Task 5), checks kept green throughout, personal-info scan (Task 4 Step 3), sequencing/handoff (Task 6). Gap: none found; first release itself is explicitly out of scope per spec sequencing.
- Placeholders: none; all code inline. Two deliberate "check the real signature first" notes (registry.addAccount, design tokens) point at exact files/lines - adaptation instructions, not gaps.
- Type consistency: `SetupWizardModel` API in Task 2's view matches Task 1's implementation (`canAdvance`, `advance`, `goBack`, `markSignedIn`, `skipSignIn`, `signedIn`, `errorMessage`, `pageURL(for:)`); tray closure names consistent (`onOpenSetupGuide`, `onCheckForUpdates`); env var names consistent between Tasks 3 and 4.

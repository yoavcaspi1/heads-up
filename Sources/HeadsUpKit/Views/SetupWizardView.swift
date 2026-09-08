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
        VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.lg) {
            progressHeader
            stepBody
            Spacer(minLength: 0)
            footer
        }
        .padding(YCDesignSystem.Spacing.lg)
        .frame(width: 520, height: 500)
        .background(YCDesignSystem.Colors.canvas)
    }

    private var progressHeader: some View {
        HStack(spacing: YCDesignSystem.Spacing.xs) {
            ForEach(model.steps.filter { $0 != .done }, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= model.step.rawValue
                          ? YCDesignSystem.Colors.accent
                          : YCDesignSystem.Colors.border)
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Text("Step \(model.stepNumber) of \(model.stepCount)")
                .font(YCDesignSystem.Typography.caption)
                .foregroundStyle(YCDesignSystem.Colors.textSecondary)
        }
    }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .welcome:
            page(title: "Welcome to Heads Up",
                 lines: model.bundledClientAvailable ? [
                    "Heads Up watches your Google Calendar and puts a full-screen alert in front of you before each meeting.",
                    "One-time setup: sign in with the Google account whose calendar you want alerts for. It takes about a minute.",
                    "Heads Up only reads your calendar. It never changes anything, and your data stays between your Mac and Google.",
                 ] : [
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
                    "Important: back on the overview, press \"Publish app\". If you leave it in Testing mode, Google disconnects the app every 7 days and alerts silently stop.",
                 ],
                 linkTitle: "Open the consent screen page")
        case .createClient:
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.sm) {
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
                        .font(YCDesignSystem.Typography.caption)
                        .foregroundStyle(YCDesignSystem.Colors.dangerText)
                }
            }
        case .signIn:
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.sm) {
                page(title: "\(model.stepNumber). Sign in with Google",
                     lines: model.bundledClientAvailable ? [
                        "Press the button below. Your browser opens Google's sign-in page.",
                        "Google may show a \"Google hasn't verified this app\" screen. That is normal for a small app like this one: click \"Advanced\", then \"Go to Heads Up (unsafe)\", then \"Allow\".",
                        "You can add more Google accounts later from Settings.",
                     ] : [
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
                        .foregroundStyle(YCDesignSystem.Colors.successText)
                }
                if let message = model.errorMessage {
                    Text(message)
                        .font(YCDesignSystem.Typography.caption)
                        .foregroundStyle(YCDesignSystem.Colors.dangerText)
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
        VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.sm) {
            Text(title)
                .font(YCDesignSystem.Typography.h2)
                .foregroundStyle(YCDesignSystem.Colors.textPrimary)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(YCDesignSystem.Typography.body)
                    .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let linkTitle, let url = SetupWizardModel.pageURL(for: model.step) {
                Button(linkTitle) { NSWorkspace.shared.open(url) }
                    .tint(YCDesignSystem.Colors.accent)
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

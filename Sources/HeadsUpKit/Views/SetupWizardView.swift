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
            if !showsAuthorNote { progressHeader }
            stepBody
            Spacer(minLength: 0)
            footer
        }
        .padding(YCDesignSystem.Spacing.lg)
        .frame(width: 520, height: 500)
        .background(YCDesignSystem.Colors.canvas)
    }

    /// The bundled-client welcome page is a personal note, not a step, so it
    /// drops the dots and the "Step x of y" label.
    private var showsAuthorNote: Bool {
        model.step == .welcome && model.bundledClientAvailable
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
            if model.bundledClientAvailable {
                authorNote
            } else {
                page(title: "Welcome to Heads Up",
                     lines: [
                        "Heads Up watches your Google Calendar and puts a full-screen alert in front of you before each meeting.",
                        "One-time setup: connect the app to your own Google account. It takes about 10 minutes and this guide walks you through every click.",
                        "You will create a free Google \"project\" that belongs to you, so your calendar data never goes through anyone else's account.",
                     ])
            }
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

    /// One icon-and-text line of the first-launch note.
    private struct WelcomeNote: Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol }
    }

    /// The three things a first-time user has to know before signing in.
    /// Outline SF Symbols only, so the column reads as quiet marginalia
    /// rather than three coloured badges.
    private static let welcomeNotes: [WelcomeNote] = [
        WelcomeNote(symbol: "desktopcomputer",
                    text: "Heads Up needs macOS 14 (Sonoma) or newer."),
        WelcomeNote(symbol: "person.badge.key",
                    text: "When you sign in, Google shows a page saying it hasn't verified this app. That is expected for a small app like this one. Click Advanced, then Go to Heads Up, then Allow."),
        WelcomeNote(symbol: "menubar.rectangle",
                    text: "There is no Dock icon. Heads Up lives in the menu bar: look for the bell at the top right of your screen."),
    ]

    /// First-launch splash for the bundled-client flow: a short personal
    /// note instead of a numbered welcome step. Note text is bodySmall so
    /// the whole letter plus the footer button fits the fixed 520x500 window
    /// without clipping.
    private var authorNote: some View {
        VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.sm) {
            Text("A note from Yoav")
                .font(YCDesignSystem.Typography.h2)
                .foregroundStyle(YCDesignSystem.Colors.textPrimary)
            Text("Thanks for trying Heads Up. It watches your Google Calendar and puts a full-screen reminder in front of you before each meeting, so you never miss one. Three things to know before you start:")
                .font(YCDesignSystem.Typography.body)
                .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.sm) {
                ForEach(Self.welcomeNotes) { note in
                    HStack(alignment: .top, spacing: YCDesignSystem.Spacing.sm) {
                        Image(systemName: note.symbol)
                            .foregroundStyle(YCDesignSystem.Colors.textMuted)
                            .frame(width: 20, alignment: .leading)
                        Text(note.text)
                            .font(YCDesignSystem.Typography.bodySmall)
                            .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, YCDesignSystem.Spacing.xs)
            Text("Yoav")
                .font(YCDesignSystem.Typography.body)
                .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                .padding(.top, YCDesignSystem.Spacing.sm)
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

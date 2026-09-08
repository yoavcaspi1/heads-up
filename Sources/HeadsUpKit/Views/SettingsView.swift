import SwiftUI
import AppKit

/// Lead-time picker label: "At event start" for 0, else "N minutes before".
/// Internal (not private) so checks can cover it directly, same convention
/// as `humanizeDuration` in AlertView.swift.
func leadTimeLabel(_ minutes: Int) -> String {
    minutes == 0 ? "At event start" : "\(minutes) minute\(minutes == 1 ? "" : "s") before"
}

/// Middle-truncates a saved OAuth client ID for display, e.g.
/// "123456789012-abc...xyz.apps.googleusercontent.com" -> shortened. Never
/// applied to the client secret, which is never displayed at all.
func truncatedMiddle(_ value: String, keep: Int = 10) -> String {
    guard value.count > keep * 2 + 3 else { return value }
    let start = value.prefix(keep)
    let end = value.suffix(keep)
    return "\(start)...\(end)"
}

/// Backing model for the Settings window. Every intent persists via
/// `settingsStore.update` (whose synchronous observer callback keeps this
/// model's own @Published mirror in sync) and, where the change affects what
/// gets fetched from Google, follows up with `scheduler.refresh()`.
@MainActor
final class SettingsModel: ObservableObject {
    // MARK: Notifications

    @Published var alertsEnabled: Bool
    @Published var menuBarCalendarEnabled: Bool

    // MARK: Google connection

    @Published var configured: Bool
    @Published var savedClientId: String?
    @Published var credentialsInvalid: Bool
    @Published var clientIdInput: String = ""
    @Published var clientSecretInput: String = ""

    // MARK: Accounts

    @Published var accounts: [GoogleAccount] = []
    @Published var isAddingAccount = false
    @Published var reconnectingAccountId: String?
    @Published var accountsError: String?

    // MARK: Calendars

    @Published var calendars: [CalendarInfo] = []

    // MARK: Timing

    @Published var alertLeadTimes: [Int]
    @Published var snoozeDurations: [Int]

    // MARK: Appearance

    @Published var alertBackground: AppSettings.AlertBackground
    @Published var appearance: AppSettings.Appearance
    @Published var eventOpenTarget: AppSettings.EventOpenTarget
    @Published var alertTitleFont: AppSettings.AlertTitleFont
    /// Sign-in goes through the client bundled with the app; the user has
    /// not pasted their own.
    @Published var usesBundledClient: Bool

    private let settingsStore: SettingsStore
    private let credentials: GoogleCredentialsStore
    private let registry: GoogleAccountsRegistry
    private let calendarClient: GoogleCalendarClient
    private let scheduler: Scheduler
    private let onTestAlert: () -> Void

    init(settingsStore: SettingsStore, credentials: GoogleCredentialsStore,
         registry: GoogleAccountsRegistry, calendarClient: GoogleCalendarClient,
         scheduler: Scheduler, onTestAlert: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.credentials = credentials
        self.registry = registry
        self.calendarClient = calendarClient
        self.scheduler = scheduler
        self.onTestAlert = onTestAlert

        let s = settingsStore.settings
        alertsEnabled = s.alertsEnabled
        menuBarCalendarEnabled = s.menuBarCalendarEnabled
        alertLeadTimes = s.alertLeadTimes
        snoozeDurations = s.snoozeDurations
        alertBackground = s.alertBackground
        appearance = s.appearance
        eventOpenTarget = s.eventOpenTarget
        alertTitleFont = s.alertTitleFont

        configured = credentials.isConfigured
        usesBundledClient = credentials.usesBundledClient
        savedClientId = credentials.credentials?.clientId
        credentialsInvalid = registry.credentialsInvalid
        accounts = registry.listAccounts()

        settingsStore.addObserver { [weak self] updated in
            self?.applySettings(updated)
        }
        scheduler.onAccountsStateChanged { [weak self] in
            guard let self else { return }
            self.credentialsInvalid = self.registry.credentialsInvalid
            self.accounts = self.registry.listAccounts()
        }
    }

    private func applySettings(_ s: AppSettings) {
        alertsEnabled = s.alertsEnabled
        menuBarCalendarEnabled = s.menuBarCalendarEnabled
        alertLeadTimes = s.alertLeadTimes
        snoozeDurations = s.snoozeDurations
        alertBackground = s.alertBackground
        appearance = s.appearance
        eventOpenTarget = s.eventOpenTarget
        alertTitleFont = s.alertTitleFont
    }

    /// Called by SettingsWindowController each time the window is shown:
    /// re-syncs everything that can drift while the window was hidden, and
    /// reloads the calendar list.
    func onWindowShow() {
        configured = credentials.isConfigured
        usesBundledClient = credentials.usesBundledClient
        savedClientId = credentials.credentials?.clientId
        credentialsInvalid = registry.credentialsInvalid
        accounts = registry.listAccounts()
        accountsError = nil
        Task { await loadCalendars() }
    }

    // MARK: - Notifications

    func setAlertsEnabled(_ value: Bool) {
        settingsStore.update { $0.alertsEnabled = value }
    }

    func setMenuBarCalendarEnabled(_ value: Bool) {
        settingsStore.update { $0.menuBarCalendarEnabled = value }
    }

    // MARK: - Google connection

    func saveCredentials() {
        let id = clientIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return }
        credentials.save(clientId: id, clientSecret: secret)
        registry.resetCredentialsInvalid()
        clientIdInput = ""
        clientSecretInput = ""
        configured = credentials.isConfigured
        usesBundledClient = credentials.usesBundledClient
        savedClientId = credentials.credentials?.clientId
        credentialsInvalid = registry.credentialsInvalid
        Task {
            await scheduler.refresh()
            await loadCalendars()
        }
    }

    func clearCredentials() {
        let alert = NSAlert()
        alert.messageText = "Remove Google credentials?"
        alert.informativeText = "This disconnects every Google account and clears the saved client ID and secret. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        registry.removeAllAccounts()
        credentials.clear()
        registry.resetCredentialsInvalid()
        accounts = []
        calendars = []
        accountsError = nil
        configured = credentials.isConfigured
        usesBundledClient = credentials.usesBundledClient
        savedClientId = nil
        credentialsInvalid = registry.credentialsInvalid
        Task { await scheduler.refresh() }
    }

    // MARK: - Accounts

    func addAccount() async {
        accountsError = nil
        isAddingAccount = true
        defer { isAddingAccount = false }
        do {
            _ = try await registry.addAccount()
            accounts = registry.listAccounts()
            credentialsInvalid = registry.credentialsInvalid
            await scheduler.refresh()
            await loadCalendars()
        } catch {
            accountsError = Self.describe(error)
        }
    }

    func removeAccount(id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.email)?"
        alert.informativeText = "Heads Up will stop showing events and alerts for this account."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        registry.removeAccount(id: id)
        accounts = registry.listAccounts()
        Task {
            await scheduler.refresh()
            await loadCalendars()
        }
    }

    func reconnectAccount(id: String) async {
        accountsError = nil
        reconnectingAccountId = id
        defer { reconnectingAccountId = nil }
        do {
            _ = try await registry.reconnectAccount(id: id)
            accounts = registry.listAccounts()
            credentialsInvalid = registry.credentialsInvalid
            await scheduler.refresh()
        } catch {
            accountsError = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case OAuthError.deniedByUser:
            return "Sign-in was cancelled."
        case OAuthError.notConfigured:
            return "Add a client ID and secret first."
        case OAuthError.invalidClient:
            return "Google rejected these credentials. Re-enter your client ID and secret."
        case OAuthError.invalidGrant:
            return "Sign-in expired. Try again."
        case OAuthError.transport(let message):
            return message
        case let AccountError.wrongAccount(expected, got):
            return "Signed in as \(got), expected \(expected). Try again and pick the same account."
        default:
            return "Something went wrong: \(error.localizedDescription)"
        }
    }

    // MARK: - Calendars

    func loadCalendars() async {
        guard configured, !accounts.isEmpty else {
            calendars = []
            return
        }
        calendars = await calendarClient.listAllCalendars()
    }

    func isCalendarEnabled(_ info: CalendarInfo) -> Bool {
        !settingsStore.settings.disabledCalendars.contains(info.key)
    }

    func setCalendarEnabled(key: String, enabled: Bool) {
        settingsStore.update { s in
            var disabled = Set(s.disabledCalendars)
            if enabled { disabled.remove(key) } else { disabled.insert(key) }
            s.disabledCalendars = Array(disabled)
        }
        Task { await scheduler.refresh() }
    }

    // MARK: - Timing

    func setLeadTime(index: Int, minutes: Int) {
        settingsStore.update { s in
            var times = s.alertLeadTimes
            guard times.indices.contains(index) else { return }
            times[index] = minutes
            s.alertLeadTimes = times
        }
    }

    func setSnoozeDuration(index: Int, minutes: Int) {
        settingsStore.update { s in
            var durations = s.snoozeDurations
            guard durations.indices.contains(index) else { return }
            durations[index] = minutes
            s.snoozeDurations = durations
        }
    }

    // MARK: - Appearance

    func setAlertBackground(_ value: AppSettings.AlertBackground) {
        settingsStore.update { $0.alertBackground = value }
    }


    func setAppearance(_ value: AppSettings.Appearance) {
        settingsStore.update { $0.appearance = value }
    }

    func setAlertTitleFont(_ value: AppSettings.AlertTitleFont) {
        settingsStore.update { $0.alertTitleFont = value }
    }

    func setEventOpenTarget(_ value: AppSettings.EventOpenTarget) {
        settingsStore.update { $0.eventOpenTarget = value }
    }

    // MARK: - Test

    func testAlert() {
        onTestAlert()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    /// Reveals the paste-your-own-client fields on top of the bundled
    /// client; off until the user asks for them.
    @State private var showCustomClientFields = false

    private let setupSteps = "Create a Google Cloud project (or reuse an existing one), enable the Calendar API, then create an OAuth client of type Desktop app. Paste its client ID and secret below."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.lg) {
                notificationsSection
                googleConnectionSection
                if model.configured {
                    accountsSection
                }
                if model.configured && !model.accounts.isEmpty {
                    calendarsSection
                }
                alertsSection
                snoozeSection
                appearanceSection
                testSection
            }
            .padding(YCDesignSystem.Spacing.md)
        }
        .background(YCDesignSystem.Colors.canvas)
        .frame(width: 480, height: 640)
    }

    // MARK: - 1. Notifications

    private var notificationsSection: some View {
        sectionCard("Notifications") {
            VStack(spacing: YCDesignSystem.Spacing.sm) {
                settingsRow("Full-screen alerts") {
                    Toggle("", isOn: Binding(get: { model.alertsEnabled }, set: model.setAlertsEnabled))
                        .toggleStyle(.switch)
                        .tint(YCDesignSystem.Colors.accent)
                        .labelsHidden()
                        .accessibilityLabel("Full-screen alerts")
                }
                settingsRow("Menu bar calendar") {
                    Toggle("", isOn: Binding(get: { model.menuBarCalendarEnabled }, set: model.setMenuBarCalendarEnabled))
                        .toggleStyle(.switch)
                        .tint(YCDesignSystem.Colors.accent)
                        .labelsHidden()
                        .accessibilityLabel("Menu bar calendar")
                }
                settingsRow("Open events in") {
                    Picker("", selection: Binding(get: { model.eventOpenTarget }, set: model.setEventOpenTarget)) {
                        Text("Google Calendar (browser)").tag(AppSettings.EventOpenTarget.googleWeb)
                        Text("Apple Calendar").tag(AppSettings.EventOpenTarget.appleCalendar)
                        Text("Notion Calendar").tag(AppSettings.EventOpenTarget.notionCalendar)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Open events in")
                    .frame(width: 200)
                }
            }
        }
    }

    // MARK: - 2. Google connection

    private var googleConnectionSection: some View {
        sectionCard("Google connection") {
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.smd) {
                if model.credentialsInvalid {
                    callout(
                        "Google rejected these credentials. Re-enter your client ID and secret.",
                        background: YCDesignSystem.Colors.dangerBg,
                        foreground: YCDesignSystem.Colors.dangerText)
                }
                if model.configured && !model.usesBundledClient {
                    HStack {
                        Text(truncatedMiddle(model.savedClientId ?? ""))
                            .font(YCDesignSystem.Typography.code)
                            .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        destructiveOutlineButton("Remove") {
                            model.clearCredentials()
                            showCustomClientFields = false
                        }
                    }
                } else if model.usesBundledClient && !showCustomClientFields {
                    HStack(alignment: .top, spacing: YCDesignSystem.Spacing.sm) {
                        Text("Using the Google connection built into Heads Up. Just add your account below.")
                            .font(YCDesignSystem.Typography.bodySmall)
                            .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Use my own client…") { showCustomClientFields = true }
                            .buttonStyle(.plain)
                            .font(YCDesignSystem.Typography.label)
                            .foregroundStyle(YCDesignSystem.Colors.link)
                    }
                } else {
                    callout(setupSteps,
                            background: YCDesignSystem.Colors.warningBg,
                            foreground: YCDesignSystem.Colors.warningText)
                    VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.xs) {
                        Text("Client ID")
                            .font(YCDesignSystem.Typography.label)
                            .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                        TextField("Client ID", text: $model.clientIdInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Client ID")
                    }
                    VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.xs) {
                        Text("Client secret")
                            .font(YCDesignSystem.Typography.label)
                            .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                        SecureField("Client secret", text: $model.clientSecretInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Client secret")
                    }
                    HStack {
                        Spacer()
                        primaryButton("Save credentials", disabled: !canSaveCredentials) {
                            model.saveCredentials()
                        }
                    }
                }
            }
        }
    }

    private var canSaveCredentials: Bool {
        !model.clientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.clientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 3. Accounts

    private var accountsSection: some View {
        sectionCard("Accounts") {
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.smd) {
                if let error = model.accountsError {
                    callout(error, background: YCDesignSystem.Colors.dangerBg, foreground: YCDesignSystem.Colors.dangerText)
                }
                if model.accounts.isEmpty {
                    Text("No Google accounts connected yet.")
                        .font(YCDesignSystem.Typography.bodySmall)
                        .foregroundStyle(YCDesignSystem.Colors.textMuted)
                } else {
                    VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.smd) {
                        ForEach(model.accounts) { account in
                            accountRow(account)
                            if account.id != model.accounts.last?.id {
                                Rectangle()
                                    .fill(YCDesignSystem.Colors.border)
                                    .frame(height: 1)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    primaryButton(model.isAddingAccount ? "Adding..." : "Add Google account",
                                  disabled: model.isAddingAccount) {
                        Task { await model.addAccount() }
                    }
                }
            }
        }
    }

    private func accountRow(_ account: GoogleAccount) -> some View {
        HStack(alignment: .top, spacing: YCDesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.xs) {
                Text(account.email)
                    .font(YCDesignSystem.Typography.body)
                    .foregroundStyle(YCDesignSystem.Colors.textPrimary)
                Text(account.name)
                    .font(YCDesignSystem.Typography.caption)
                    .foregroundStyle(YCDesignSystem.Colors.textMuted)
                if account.needsReconnect {
                    Text("Sign-in expired")
                        .font(YCDesignSystem.Typography.caption)
                        .foregroundStyle(YCDesignSystem.Colors.dangerText)
                }
            }
            Spacer()
            HStack(spacing: YCDesignSystem.Spacing.sm) {
                if account.needsReconnect {
                    let isBusy = model.reconnectingAccountId == account.id
                    primaryButton(isBusy ? "Reconnecting..." : "Reconnect", disabled: isBusy) {
                        Task { await model.reconnectAccount(id: account.id) }
                    }
                }
                quietButton("Remove") { model.removeAccount(id: account.id) }
            }
        }
    }

    // MARK: - 4. Calendars

    private var calendarsSection: some View {
        sectionCard("Calendars") {
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.smd) {
                if model.calendars.isEmpty {
                    Text("No calendars found yet.")
                        .font(YCDesignSystem.Typography.bodySmall)
                        .foregroundStyle(YCDesignSystem.Colors.textMuted)
                } else {
                    ForEach(model.calendars, id: \.key) { info in
                        calendarRow(info)
                    }
                }
            }
        }
    }

    private func calendarRow(_ info: CalendarInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.xs) {
                Text(info.calendarName)
                    .font(YCDesignSystem.Typography.body)
                    .foregroundStyle(YCDesignSystem.Colors.textPrimary)
                if model.accounts.count > 1 {
                    Text(info.accountEmail)
                        .font(YCDesignSystem.Typography.caption)
                        .foregroundStyle(YCDesignSystem.Colors.textMuted)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.isCalendarEnabled(info) },
                set: { model.setCalendarEnabled(key: info.key, enabled: $0) }))
                .toggleStyle(.switch)
                .tint(YCDesignSystem.Colors.accent)
                .labelsHidden()
                .accessibilityLabel(info.calendarName)
        }
    }

    // MARK: - 5. Alerts

    private var alertsSection: some View {
        sectionCard("Alerts") {
            VStack(spacing: YCDesignSystem.Spacing.sm) {
                settingsRow("First alert") { leadTimePicker(index: 0) }
                settingsRow("Second alert") { leadTimePicker(index: 1) }
            }
        }
    }

    private func leadTimePicker(index: Int) -> some View {
        Picker("", selection: Binding(
            get: { model.alertLeadTimes.indices.contains(index) ? model.alertLeadTimes[index] : AppSettings.defaults.alertLeadTimes[index] },
            set: { model.setLeadTime(index: index, minutes: $0) })) {
            ForEach(AppSettings.allowedLeadTimes, id: \.self) { minutes in
                Text(leadTimeLabel(minutes)).tag(minutes)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(index == 0 ? "First alert" : "Second alert")
        .frame(width: 200)
    }

    // MARK: - 6. Snooze

    private var snoozeSection: some View {
        sectionCard("Snooze") {
            VStack(spacing: YCDesignSystem.Spacing.sm) {
                settingsRow("First snooze button") { snoozePicker(index: 0) }
                settingsRow("Second snooze button") { snoozePicker(index: 1) }
            }
        }
    }

    private func snoozePicker(index: Int) -> some View {
        Picker("", selection: Binding(
            get: { model.snoozeDurations.indices.contains(index) ? model.snoozeDurations[index] : AppSettings.defaults.snoozeDurations[index] },
            set: { model.setSnoozeDuration(index: index, minutes: $0) })) {
            ForEach(AppSettings.allowedSnoozeMinutes, id: \.self) { minutes in
                Text(humanizeDuration(minutes)).tag(minutes)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(index == 0 ? "First snooze button" : "Second snooze button")
        .frame(width: 200)
    }

    // MARK: - 7. Alert appearance

    private var appearanceSection: some View {
        sectionCard("Alert appearance") {
            VStack(spacing: YCDesignSystem.Spacing.sm) {
                settingsRow("Background") {
                    Picker("", selection: Binding(get: { model.alertBackground }, set: model.setAlertBackground)) {
                        Text("Solid").tag(AppSettings.AlertBackground.solid)
                        Text("Blur").tag(AppSettings.AlertBackground.blur)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Background")
                    .frame(width: 140)
                }
                settingsRow("Title font") {
                    Picker("", selection: Binding(get: { model.alertTitleFont }, set: model.setAlertTitleFont)) {
                        Text("Syne").tag(AppSettings.AlertTitleFont.syne)
                        Text("DM Sans").tag(AppSettings.AlertTitleFont.dmSans)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Title font")
                    .frame(width: 140)
                }
                settingsRow("App appearance") {
                    Picker("", selection: Binding(get: { model.appearance }, set: model.setAppearance)) {
                        Text("System").tag(AppSettings.Appearance.system)
                        Text("Light").tag(AppSettings.Appearance.light)
                        Text("Dark").tag(AppSettings.Appearance.dark)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("App appearance")
                    .frame(width: 140)
                }
            }
        }
    }

    // MARK: - 8. Test

    private var testSection: some View {
        sectionCard("Test") {
            HStack {
                Spacer()
                secondaryButton("Show test alert") { model.testAlert() }
            }
        }
    }

    // MARK: - Shared row / card scaffolding

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.smd) {
            Text(title)
                .font(YCDesignSystem.Typography.h4)
                .foregroundStyle(YCDesignSystem.Colors.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YCDesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.large)
                .fill(YCDesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.large)
                .stroke(YCDesignSystem.Colors.border, lineWidth: 1)
        )
    }

    /// Label left, control right, vertically centred: the preferences-pane
    /// row rule from COMPONENT SPECS/17_PREFERENCES_PANE.md.
    private func settingsRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
                .font(YCDesignSystem.Typography.body)
                .foregroundStyle(YCDesignSystem.Colors.textPrimary)
            Spacer()
            control()
        }
        .frame(minHeight: YCDesignSystem.Rows.minHeight)
    }

    private func callout(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(YCDesignSystem.Typography.bodySmall)
            .foregroundStyle(foreground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YCDesignSystem.Spacing.smd)
            .background(
                RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium)
                    .fill(background)
            )
    }

    private func primaryButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(YCDesignSystem.Typography.button)
                .foregroundStyle(YCDesignSystem.Colors.textOnAccent)
                .padding(.horizontal, YCDesignSystem.Spacing.md)
                .frame(height: 36)
                .background(disabled ? YCDesignSystem.Colors.disabledBg : YCDesignSystem.Colors.accent)
                .clipShape(RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(YCDesignSystem.Typography.button)
                .foregroundStyle(YCDesignSystem.Colors.textPrimary)
                .padding(.horizontal, YCDesignSystem.Spacing.md)
                .frame(height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium)
                        .stroke(YCDesignSystem.Colors.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func destructiveOutlineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(YCDesignSystem.Typography.button)
                .foregroundStyle(YCDesignSystem.Colors.dangerText)
                .padding(.horizontal, YCDesignSystem.Spacing.md)
                .frame(height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium)
                        .stroke(YCDesignSystem.Colors.dangerText, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(YCDesignSystem.Typography.label)
                .foregroundStyle(YCDesignSystem.Colors.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

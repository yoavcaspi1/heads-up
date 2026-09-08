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
    /// nil when no updater is running (bare `swift run` builds have no
    /// bundle for Sparkle to update); the button is disabled then.
    private let onCheckForUpdates: (() -> Void)?

    init(settingsStore: SettingsStore, credentials: GoogleCredentialsStore,
         registry: GoogleAccountsRegistry, calendarClient: GoogleCalendarClient,
         scheduler: Scheduler, onTestAlert: @escaping () -> Void,
         onCheckForUpdates: (() -> Void)? = nil) {
        self.settingsStore = settingsStore
        self.credentials = credentials
        self.registry = registry
        self.calendarClient = calendarClient
        self.scheduler = scheduler
        self.onTestAlert = onTestAlert
        self.onCheckForUpdates = onCheckForUpdates

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

    // MARK: - Updates

    var canCheckForUpdates: Bool { onCheckForUpdates != nil }

    func checkForUpdates() {
        onCheckForUpdates?()
    }

    /// "Heads Up 1.5.0 (37)" from the running bundle; a bare executable
    /// has neither value and reads "Heads Up (development build)".
    var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return Self.versionLabel(short: info["CFBundleShortVersionString"] as? String,
                                 build: info["CFBundleVersion"] as? String)
    }

    nonisolated static func versionLabel(short: String?, build: String?) -> String {
        guard let short, !short.isEmpty else { return "Heads Up (development build)" }
        if let build, !build.isEmpty { return "Heads Up \(short) (\(build))" }
        return "Heads Up \(short)"
    }
}

/// Sidebar tabs. Declaration order is the sidebar order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case google = "Google"
    case alerts = "Alerts"
    case about = "About"

    var id: String { rawValue }

    /// Outline symbol variants: the YC icon language is stroke, so sidebar
    /// glyphs render as ink outlines, not filled colour tiles.
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .google: return "person.crop.circle"
        case .alerts: return "bell"
        case .about: return "info.circle"
        }
    }
}

/// Settings in the Call Recorder preferences layout: a flat canvas sidebar
/// of tabs on the left, a scrolling detail pane of eyebrow-headed cards on
/// the right. Every control and its binding is unchanged from the single
/// column this replaced; only the arrangement moved.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    @State private var selectedTab: SettingsTab = .general
    /// Reveals the paste-your-own-client fields on top of the bundled
    /// client; off until the user asks for them.
    @State private var showCustomClientFields = false

    static let preferredSize = NSSize(width: 760, height: 600)

    private let setupSteps = "Create a Google Cloud project (or reuse an existing one), enable the Calendar API, then create an OAuth client of type Desktop app. Paste its client ID and secret below."

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(YCDesignSystem.Colors.border)
                .frame(width: 1)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A flexible frame, not a fixed one: a rigid root view pins the
        // window size through the hosting view and the resizable style
        // mask stops meaning anything.
        .frame(minWidth: 680, idealWidth: Self.preferredSize.width, maxWidth: .infinity,
               minHeight: 520, idealHeight: Self.preferredSize.height, maxHeight: .infinity)
        .background(YCDesignSystem.Colors.canvas)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsSidebarRow(title: tab.rawValue, icon: tab.icon, isSelected: selectedTab == tab)
                    .onTapGesture { selectedTab = tab }
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 204)
        .background(YCDesignSystem.Colors.canvas)
    }

    @ViewBuilder private var detail: some View {
        switch selectedTab {
        case .general: generalTab
        case .google: googleTab
        case .alerts: alertsTab
        case .about: aboutTab
        }
    }

    // MARK: - General

    private var generalTab: some View {
        SettingsDetailPane {
            SettingsSection(title: "Notifications") {
                SettingsRow(title: "Full-screen alerts",
                            subtitle: "Put a full-screen alert in front of you before each meeting.") {
                    SettingsToggle(isOn: Binding(get: { model.alertsEnabled }, set: model.setAlertsEnabled))
                        .accessibilityLabel("Full-screen alerts")
                }
                SettingsRow(title: "Menu bar calendar",
                            subtitle: "Show the next meeting and its countdown in the menu bar; click it for the day list.",
                            showDivider: false) {
                    SettingsToggle(isOn: Binding(get: { model.menuBarCalendarEnabled }, set: model.setMenuBarCalendarEnabled))
                        .accessibilityLabel("Menu bar calendar")
                }
            }

            SettingsSection(title: "Events") {
                SettingsRow(title: "Open events in",
                            subtitle: "Where a clicked event in the calendar list opens.",
                            showDivider: false) {
                    SettingsPicker(selection: Binding(get: { model.eventOpenTarget }, set: model.setEventOpenTarget)) {
                        Text("Google Calendar (browser)").tag(AppSettings.EventOpenTarget.googleWeb)
                        Text("Apple Calendar").tag(AppSettings.EventOpenTarget.appleCalendar)
                        Text("Notion Calendar").tag(AppSettings.EventOpenTarget.notionCalendar)
                    }
                    .accessibilityLabel("Open events in")
                }
            }

            SettingsSection(title: "Appearance") {
                SettingsRow(title: "App appearance",
                            subtitle: "Light or dark for the alert, the calendar and this window.",
                            showDivider: false) {
                    SettingsPicker(selection: Binding(get: { model.appearance }, set: model.setAppearance)) {
                        Text("System").tag(AppSettings.Appearance.system)
                        Text("Light").tag(AppSettings.Appearance.light)
                        Text("Dark").tag(AppSettings.Appearance.dark)
                    }
                    .accessibilityLabel("App appearance")
                }
            }
        }
    }

    // MARK: - Google

    private var googleTab: some View {
        SettingsDetailPane {
            SettingsSection(title: "Google connection") {
                VStack(alignment: .leading, spacing: 0) {
                    if model.credentialsInvalid {
                        SettingsCallout(severity: .danger,
                                        message: "Google rejected these credentials. Re-enter your client ID and secret.")
                            .padding(14)
                    }
                    if model.configured && !model.usesBundledClient {
                        SettingsRow(title: "Your own Google client",
                                    subtitle: truncatedMiddle(model.savedClientId ?? ""),
                                    showDivider: false) {
                            SettingsButton(title: "Remove", isDestructive: true) {
                                model.clearCredentials()
                                showCustomClientFields = false
                            }
                        }
                    } else if model.usesBundledClient && !showCustomClientFields {
                        SettingsRow(title: "Built-in Google connection",
                                    subtitle: "Sign-in goes through the client that ships with Heads Up. Just add your account below.",
                                    showDivider: false) {
                            SettingsButton(title: "Use my own client…") { showCustomClientFields = true }
                        }
                    } else {
                        customClientForm
                    }
                }
            }

            if model.configured {
                accountsSection
            }

            if model.configured && !model.accounts.isEmpty {
                calendarsSection
            }
        }
    }

    private var customClientForm: some View {
        VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.smd) {
            SettingsCallout(severity: .info, message: setupSteps)
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
            HStack(spacing: YCDesignSystem.Spacing.sm) {
                Spacer()
                if model.usesBundledClient {
                    Button("Cancel") { showCustomClientFields = false }
                        .buttonStyle(YCSecondaryButtonStyle())
                }
                Button("Save credentials") { model.saveCredentials() }
                    .buttonStyle(YCPrimaryButtonStyle())
                    .disabled(!canSaveCredentials)
            }
        }
        .padding(14)
    }

    private var canSaveCredentials: Bool {
        !model.clientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.clientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var accountsSection: some View {
        SettingsSection(title: "Accounts") {
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.accountsError {
                    SettingsCallout(severity: .danger, message: error)
                        .padding(14)
                }
                if model.accounts.isEmpty {
                    Text("No Google accounts connected yet.")
                        .font(YCDesignSystem.Typography.bodySmall)
                        .foregroundStyle(YCDesignSystem.Colors.textMuted)
                        .padding(14)
                } else {
                    ForEach(model.accounts) { account in
                        accountRow(account)
                    }
                }
                HStack {
                    Spacer()
                    Button(model.isAddingAccount ? "Adding..." : "Add Google account") {
                        Task { await model.addAccount() }
                    }
                    .buttonStyle(YCPrimaryButtonStyle())
                    .disabled(model.isAddingAccount)
                }
                .padding(14)
            }
        }
    }

    private func accountRow(_ account: GoogleAccount) -> some View {
        SettingsRow(title: account.email, subtitle: account.name) {
            HStack(spacing: YCDesignSystem.Spacing.sm) {
                if account.needsReconnect {
                    StatusPill(text: "Sign-in expired", color: YCDesignSystem.Colors.dangerText,
                               icon: "exclamationmark.triangle.fill")
                    let isBusy = model.reconnectingAccountId == account.id
                    Button(isBusy ? "Reconnecting..." : "Reconnect") {
                        Task { await model.reconnectAccount(id: account.id) }
                    }
                    .buttonStyle(YCPrimaryButtonStyle())
                    .disabled(isBusy)
                }
                SettingsButton(title: "Remove", isDestructive: true) { model.removeAccount(id: account.id) }
            }
        }
    }

    private var calendarsSection: some View {
        SettingsSection(title: "Calendars") {
            if model.calendars.isEmpty {
                Text("No calendars found yet.")
                    .font(YCDesignSystem.Typography.bodySmall)
                    .foregroundStyle(YCDesignSystem.Colors.textMuted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.calendars, id: \.key) { info in
                    SettingsRow(title: info.calendarName,
                                subtitle: model.accounts.count > 1 ? info.accountEmail : nil,
                                showDivider: info.key != model.calendars.last?.key) {
                        SettingsToggle(isOn: Binding(
                            get: { model.isCalendarEnabled(info) },
                            set: { model.setCalendarEnabled(key: info.key, enabled: $0) }))
                            .accessibilityLabel(info.calendarName)
                    }
                }
            }
        }
    }

    // MARK: - Alerts

    private var alertsTab: some View {
        SettingsDetailPane {
            SettingsSection(title: "Timing") {
                SettingsRow(title: "First alert",
                            subtitle: "How long before the meeting the first full-screen alert fires.") {
                    leadTimePicker(index: 0)
                }
                SettingsRow(title: "Second alert",
                            subtitle: "A second alert, closer to the start.",
                            showDivider: false) {
                    leadTimePicker(index: 1)
                }
            }

            SettingsSection(title: "Snooze") {
                SettingsRow(title: "First snooze button",
                            subtitle: "The quick snooze offered on the alert.") {
                    snoozePicker(index: 0)
                }
                SettingsRow(title: "Second snooze button", showDivider: false) {
                    snoozePicker(index: 1)
                }
            }

            SettingsSection(title: "Appearance") {
                SettingsRow(title: "Background",
                            subtitle: "Solid canvas, or a blur of whatever is behind the alert.") {
                    SettingsPicker(selection: Binding(get: { model.alertBackground }, set: model.setAlertBackground)) {
                        Text("Solid").tag(AppSettings.AlertBackground.solid)
                        Text("Blur").tag(AppSettings.AlertBackground.blur)
                    }
                    .accessibilityLabel("Background")
                }
                SettingsRow(title: "Title font",
                            subtitle: "Typeface for the meeting title on the alert.",
                            showDivider: false) {
                    SettingsPicker(selection: Binding(get: { model.alertTitleFont }, set: model.setAlertTitleFont)) {
                        Text("Syne").tag(AppSettings.AlertTitleFont.syne)
                        Text("DM Sans").tag(AppSettings.AlertTitleFont.dmSans)
                    }
                    .accessibilityLabel("Title font")
                }
            }

            SettingsSection(title: "Test") {
                SettingsRow(title: "Preview the alert",
                            subtitle: "Shows a full-screen test alert with the current settings.",
                            showDivider: false) {
                    SettingsButton(title: "Show test alert") { model.testAlert() }
                }
            }
        }
    }

    private func leadTimePicker(index: Int) -> some View {
        SettingsPicker(selection: Binding(
            get: { model.alertLeadTimes.indices.contains(index) ? model.alertLeadTimes[index] : AppSettings.defaults.alertLeadTimes[index] },
            set: { model.setLeadTime(index: index, minutes: $0) })) {
            ForEach(AppSettings.allowedLeadTimes, id: \.self) { minutes in
                Text(leadTimeLabel(minutes)).tag(minutes)
            }
        }
        .accessibilityLabel(index == 0 ? "First alert" : "Second alert")
    }

    private func snoozePicker(index: Int) -> some View {
        SettingsPicker(selection: Binding(
            get: { model.snoozeDurations.indices.contains(index) ? model.snoozeDurations[index] : AppSettings.defaults.snoozeDurations[index] },
            set: { model.setSnoozeDuration(index: index, minutes: $0) })) {
            ForEach(AppSettings.allowedSnoozeMinutes, id: \.self) { minutes in
                Text(humanizeDuration(minutes)).tag(minutes)
            }
        }
        .accessibilityLabel(index == 0 ? "First snooze button" : "Second snooze button")
    }

    // MARK: - About

    private var aboutTab: some View {
        SettingsDetailPane {
            SettingsSection(title: "Application") {
                HStack(spacing: 16) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Heads Up")
                            .font(YCDesignSystem.Typography.h2)
                            .foregroundStyle(YCDesignSystem.Colors.textPrimary)
                        Text(model.versionLabel.replacingOccurrences(of: "Heads Up ", with: "Version "))
                            .font(.system(size: 12))
                            .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                        Button("Check for Updates…") { model.checkForUpdates() }
                            .buttonStyle(YCSecondaryButtonStyle())
                            .disabled(!model.canCheckForUpdates)
                        Text("Developer: Yoav Caspi")
                            .font(.system(size: 12))
                            .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                        Text("com.yoavcaspi.headsup")
                            .font(YCDesignSystem.Typography.code)
                            .foregroundStyle(YCDesignSystem.Colors.textMuted)
                    }
                    Spacer()
                }
                .padding(14)
            }

            SettingsSection(title: "About") {
                Text("Watches your Google Calendar from the menu bar and puts a full-screen alert in front of you before each meeting, with a Join button for the video call and snooze. The bell shows the next meeting and its countdown; click it for the day-by-day list.")
                    .font(.system(size: 12))
                    .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                    .lineSpacing(4)
                    .padding(14)
            }

            SettingsSection(title: "Updates") {
                Text("Heads Up checks for updates every 6 hours, downloads them automatically, and installs them the next time it relaunches.")
                    .font(.system(size: 12))
                    .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                    .lineSpacing(4)
                    .padding(14)
            }
        }
    }
}

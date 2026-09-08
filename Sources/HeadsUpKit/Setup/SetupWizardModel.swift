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
    /// True when the app ships its own OAuth client: the four Google Cloud
    /// console pages are skipped and the guide is welcome, sign in, done.
    public let bundledClientAvailable: Bool
    /// The pages this run of the guide walks through, in order.
    public let steps: [SetupStep]

    private struct PersistedState: Codable { var step: Int }

    public init(stateURL: URL,
                saveCredentials: @escaping (String, String) -> Void,
                credentialsConfigured: @escaping () -> Bool,
                bundledClientAvailable: Bool = false) {
        self.stateURL = stateURL
        self.saveCredentials = saveCredentials
        self.credentialsConfigured = credentialsConfigured
        self.bundledClientAvailable = bundledClientAvailable
        let steps: [SetupStep] = bundledClientAvailable ? [.welcome, .signIn, .done] : SetupStep.allCases
        self.steps = steps
        // A persisted step that this flow does not contain (e.g. a console
        // page saved by a build without a bundled client) restarts at
        // welcome rather than stranding the guide on a page it cannot show.
        if let data = try? Data(contentsOf: stateURL),
           let persisted = try? JSONDecoder().decode(PersistedState.self, from: data),
           let restored = SetupStep(rawValue: persisted.step),
           steps.contains(restored) {
            step = restored
        } else {
            step = .welcome
        }
    }

    /// The guide self-opens until the app can actually alert: a usable
    /// client and at least one connected account. A guide the user already
    /// finished (or skipped out of) never nags again; the tray menu's
    /// "Setup Guide" is the way back in.
    public static func shouldAutoShow(credentialsConfigured: Bool, hasAccounts: Bool,
                                      finishedBefore: Bool) -> Bool {
        !finishedBefore && !(credentialsConfigured && hasAccounts)
    }

    public var finished: Bool { step == .done }

    /// 1-based position of the current page for the "Step x of y" header;
    /// the done page counts as the last numbered step.
    public var stepNumber: Int {
        min(stepIndex + 1, stepCount)
    }

    public var stepCount: Int { steps.count - 1 }

    private var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

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
        guard canAdvance, stepIndex + 1 < steps.count else { return }
        let next = steps[stepIndex + 1]
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
        guard stepIndex > 0 else { return }
        let previous = steps[stepIndex - 1]
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

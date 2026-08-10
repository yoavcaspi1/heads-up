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

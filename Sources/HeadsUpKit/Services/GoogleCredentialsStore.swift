import Foundation

struct GoogleClientCredentials: Codable, Equatable {
    let clientId: String
    let clientSecret: String
}

/// The Google OAuth Desktop-app client the app signs in with. Two sources,
/// in priority order: a client the user pasted themselves (Keychain, the
/// "advanced" path), else the one bundled into Info.plist at build time.
/// Release builds ship the maintainer's client so friends only have to sign
/// in; a bare `swift run` has no bundle and so no bundled client. Google
/// treats desktop-app client secrets as non-confidential by design, which
/// is why bundling is acceptable; the secret still never lives in git.
final class GoogleCredentialsStore {
    static let bundledClientIdKey = "HeadsUpGoogleClientID"
    static let bundledClientSecretKey = "HeadsUpGoogleClientSecret"

    private static let key = "google-client-credentials"
    private let secrets: SecretStore
    private let bundled: GoogleClientCredentials?
    /// In-memory copy so repeated reads never re-hit the Keychain (and its
    /// permission prompts) once a value has been loaded.
    private var cache: GoogleClientCredentials?
    private var loaded = false

    init(secrets: SecretStore,
         bundled: GoogleClientCredentials? = GoogleCredentialsStore.bundled(from: Bundle.main.infoDictionary ?? [:])) {
        self.secrets = secrets
        self.bundled = bundled
    }

    /// The client written into Info.plist by build_app.sh, if any. Blank
    /// or missing keys mean none.
    static func bundled(from info: [String: Any]) -> GoogleClientCredentials? {
        let id = (info[bundledClientIdKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = (info[bundledClientSecretKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return GoogleClientCredentials(clientId: id, clientSecret: secret)
    }

    /// The user's own client, if they pasted one. Nil for the bundled path.
    var customCredentials: GoogleClientCredentials? {
        if loaded { return cache }
        if let data = secrets.data(for: Self.key) {
            cache = try? JSONDecoder().decode(GoogleClientCredentials.self, from: data)
        } else {
            cache = nil
        }
        loaded = true
        return cache
    }

    /// What OAuth actually signs in with: the user's own client wins.
    var credentials: GoogleClientCredentials? { customCredentials ?? bundled }

    /// Reads the stored credentials once on a background queue so a pending
    /// keychain permission prompt can never block the main thread at launch.
    /// The completion runs on the main queue.
    func preload(_ completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var value: GoogleClientCredentials?
            if let self, let data = self.secrets.data(for: Self.key) {
                value = try? JSONDecoder().decode(GoogleClientCredentials.self, from: data)
            }
            DispatchQueue.main.async {
                if let self {
                    self.cache = value
                    self.loaded = true
                }
                completion()
            }
        }
    }

    var isConfigured: Bool { credentials != nil }
    var hasBundledClient: Bool { bundled != nil }
    /// True when sign-in goes through the bundled client, i.e. the user has
    /// not pasted their own.
    var usesBundledClient: Bool { customCredentials == nil && bundled != nil }

    func save(clientId: String, clientSecret: String) {
        let creds = GoogleClientCredentials(
            clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let data = try JSONEncoder().encode(creds)
            secrets.set(data, for: Self.key)
        } catch {
            NSLog("HeadsUp failed to encode Google credentials: %@", error.localizedDescription)
        }
        cache = creds
        loaded = true
    }

    /// Forgets the user's own client; sign-in falls back to the bundled one.
    func clear() {
        secrets.delete(Self.key)
        cache = nil
        loaded = true
    }
}

import Foundation

struct GoogleClientCredentials: Codable, Equatable {
    let clientId: String
    let clientSecret: String
}

/// The user's own Google OAuth Desktop-app client, never bundled with the app.
/// Stored as one JSON blob in the secret store.
final class GoogleCredentialsStore {
    private static let key = "google-client-credentials"
    private let secrets: SecretStore
    /// In-memory copy so repeated reads never re-hit the Keychain (and its
    /// permission prompts) once a value has been loaded.
    private var cache: GoogleClientCredentials?
    private var loaded = false

    init(secrets: SecretStore) { self.secrets = secrets }

    var credentials: GoogleClientCredentials? {
        if loaded { return cache }
        if let data = secrets.data(for: Self.key) {
            cache = try? JSONDecoder().decode(GoogleClientCredentials.self, from: data)
        } else {
            cache = nil
        }
        loaded = true
        return cache
    }

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

    func clear() {
        secrets.delete(Self.key)
        cache = nil
        loaded = true
    }
}

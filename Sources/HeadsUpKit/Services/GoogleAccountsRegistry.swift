import Foundation

enum AccountError: Error, Equatable {
    case wrongAccount(expected: String, got: String)
}

/// Multi-account registry persisted as accounts.json. Tracks two failure
/// modes separately, mirroring the original: per-account dead refresh tokens
/// (needsReconnect, fixable by re-consenting the SAME account) and a global
/// invalid OAuth client (credentialsInvalid, only fixable by re-entering
/// correct client credentials).
final class GoogleAccountsRegistry {
    private let fileURL: URL
    private let oauth: GoogleOAuth
    private var accounts: [GoogleAccount] = []
    private var needsReconnect: Set<String> = []
    private(set) var credentialsInvalid = false
    /// Seam for tests: defaults to the real OAuth refresh call.
    private var tokenFetcher: ((GoogleAccount) async throws -> String)?

    init(directory: URL, oauth: GoogleOAuth) {
        self.fileURL = directory.appendingPathComponent("accounts.json")
        self.oauth = oauth
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([GoogleAccount].self, from: data) {
            self.accounts = decoded
        }
    }

    // MARK: - Listing

    func listAccounts() -> [GoogleAccount] {
        accounts.map { acct in
            var a = acct
            a.needsReconnect = needsReconnect.contains(acct.id)
            return a
        }
    }

    var hasAccounts: Bool { !accounts.isEmpty }
    var anyAccountNeedsReconnect: Bool { !needsReconnect.isEmpty }

    // MARK: - Mutation

    /// Internal insert used by addAccount/reconnect and by tests.
    func addAccountRecord(_ account: GoogleAccount) {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        needsReconnect.remove(account.id)
        persist()
    }

    func addAccount() async throws -> GoogleAccount {
        let providerId = "google-\(Int(Date().timeIntervalSince1970 * 1000))"
        let info = try await oauth.authorize(providerId: providerId)
        // Same email already connected: the fresh tokens under the OLD
        // providerId would leak, so move the new tokens over and keep one row.
        if let existing = accounts.first(where: { $0.id == info.email }) {
            if let tokens = oauth.loadTokens(providerId: providerId) {
                oauth.saveTokens(tokens, providerId: existing.providerId)
            }
            oauth.deleteTokens(providerId: providerId)
            needsReconnect.remove(existing.id)
            return existing
        }
        let account = GoogleAccount(id: info.email, email: info.email,
                                    name: info.name ?? info.email, providerId: providerId)
        addAccountRecord(account)
        return account
    }

    func removeAccount(id: String) {
        if let acct = accounts.first(where: { $0.id == id }) {
            oauth.deleteTokens(providerId: acct.providerId)
        }
        accounts.removeAll { $0.id == id }
        needsReconnect.remove(id)
        persist()
    }

    func removeAllAccounts() {
        for acct in accounts { oauth.deleteTokens(providerId: acct.providerId) }
        accounts = []
        needsReconnect = []
        persist()
    }

    /// Re-runs consent under the SAME providerId so fresh tokens overwrite the
    /// dead ones. Verifies the user picked the same Google account.
    func reconnectAccount(id: String) async throws -> GoogleAccount {
        guard let acct = accounts.first(where: { $0.id == id }) else {
            throw OAuthError.invalidGrant
        }
        let info = try await oauth.authorize(providerId: acct.providerId)
        guard info.email == acct.id else {
            oauth.deleteTokens(providerId: acct.providerId)
            throw AccountError.wrongAccount(expected: acct.id, got: info.email)
        }
        needsReconnect.remove(id)
        return acct
    }

    // MARK: - Tokens

    func setTokenFetcher(_ fetcher: @escaping (GoogleAccount) async throws -> String) {
        self.tokenFetcher = fetcher
    }

    /// nil on any failure. invalid_grant flags the account for reconnect,
    /// invalid_client flags the shared client credentials, transient errors
    /// flag nothing.
    func accessToken(for account: GoogleAccount) async -> String? {
        do {
            let fetch = tokenFetcher ?? { [oauth] in try await oauth.accessToken(providerId: $0.providerId) }
            let token = try await fetch(account)
            needsReconnect.remove(account.id)
            return token
        } catch OAuthError.invalidGrant {
            needsReconnect.insert(account.id)
            return nil
        } catch OAuthError.invalidClient {
            credentialsInvalid = true
            return nil
        } catch {
            return nil
        }
    }

    func resetCredentialsInvalid() {
        credentialsInvalid = false
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(accounts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

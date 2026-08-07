import Foundation
import AppKit

enum OAuthError: Error, Equatable {
    case notConfigured
    case invalidGrant
    case invalidClient
    case deniedByUser
    case transport(String)
}

struct TokenSet: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

struct UserInfo: Codable, Equatable {
    let email: String
    let name: String?
}

/// Google installed-app OAuth: browser + loopback redirect + PKCE.
/// One token set per providerId (one per connected account).
final class GoogleOAuth {
    private let credentials: GoogleCredentialsStore
    private let secrets: SecretStore
    private let session: URLSession
    private let openURL: (URL) -> Void
    private let now: () -> Date

    static let scopes = "https://www.googleapis.com/auth/calendar.readonly openid email profile"
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let userinfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

    init(credentials: GoogleCredentialsStore,
         secrets: SecretStore,
         session: URLSession = .shared,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         now: @escaping () -> Date = Date.init) {
        self.credentials = credentials
        self.secrets = secrets
        self.session = session
        self.openURL = openURL
        self.now = now
    }

    // MARK: - Token persistence

    private func tokenKey(_ providerId: String) -> String { "tokens-\(providerId)" }

    func saveTokens(_ tokens: TokenSet, providerId: String) {
        if let data = try? JSONEncoder().encode(tokens) {
            secrets.set(data, for: tokenKey(providerId))
        }
    }

    func loadTokens(providerId: String) -> TokenSet? {
        guard let data = secrets.data(for: tokenKey(providerId)) else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    func deleteTokens(providerId: String) {
        secrets.delete(tokenKey(providerId))
    }

    // MARK: - Error classification

    /// Maps a token-endpoint HTTP response to a typed error. nil = success.
    static func classify(status: Int, body: Data) -> OAuthError? {
        guard status >= 400 else { return nil }
        struct ErrBody: Codable { let error: String? }
        let code = (try? JSONDecoder().decode(ErrBody.self, from: body))?.error ?? ""
        switch code {
        case "invalid_grant": return .invalidGrant
        case "invalid_client", "unauthorized_client": return .invalidClient
        default: return .transport("HTTP \(status): \(String(data: body, encoding: .utf8) ?? "")")
        }
    }

    // MARK: - Authorize (interactive)

    /// Runs the full browser consent flow and stores tokens for providerId.
    func authorize(providerId: String) async throws -> UserInfo {
        guard let creds = credentials.credentials else { throw OAuthError.notConfigured }

        let pkce = PKCE()
        let state = UUID().uuidString
        let server = LoopbackRedirectServer()
        _ = try server.start()
        defer { server.stop() }

        var comps = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: creds.clientId),
            URLQueryItem(name: "redirect_uri", value: server.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        guard let authURL = comps.url else {
            throw OAuthError.transport("failed to build authorization URL")
        }
        openURL(authURL)

        let redirect: RedirectResult
        do {
            redirect = try await server.waitForCode(timeout: 300)
        } catch let e as LoopbackError where e == .deniedByUser {
            throw OAuthError.deniedByUser
        } catch let e as LoopbackError where e == .timeout {
            // The loopback server's own error is a generic transport failure
            // to the caller; give the user something actionable instead of
            // "the request timed out" bubbling up from deep in URLSession-land.
            throw OAuthError.transport("Sign-in timed out, please try again")
        }
        guard redirect.state == state else {
            // A mismatched state means this redirect did not originate from
            // the authorization request we just sent, so the code cannot be
            // trusted: treat it the same as any other malformed redirect.
            throw OAuthError.transport("authorization redirect failed state validation")
        }
        let code = redirect.code

        let tokens = try await exchange(code: code, verifier: pkce.verifier,
                                        redirectURI: server.redirectURI, creds: creds)
        saveTokens(tokens, providerId: providerId)
        return try await fetchUserInfo(accessToken: tokens.accessToken)
    }

    private func exchange(code: String, verifier: String, redirectURI: String,
                          creds: GoogleClientCredentials) async throws -> TokenSet {
        let form = [
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        let (data, status) = try await postForm(Self.tokenEndpoint, form: form)
        if let error = Self.classify(status: status, body: data) { throw error }
        struct Resp: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let resp: Resp
        do {
            resp = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw OAuthError.transport("unexpected token response: \(error.localizedDescription)")
        }
        guard let refresh = resp.refresh_token else {
            throw OAuthError.transport("Google did not return a refresh token")
        }
        return TokenSet(accessToken: resp.access_token, refreshToken: refresh,
                        expiry: now().addingTimeInterval(resp.expires_in))
    }

    // MARK: - Access tokens (refresh)

    /// Returns a valid access token for the account, refreshing if needed.
    func accessToken(providerId: String) async throws -> String {
        guard let creds = credentials.credentials else { throw OAuthError.notConfigured }
        guard var tokens = loadTokens(providerId: providerId) else { throw OAuthError.invalidGrant }

        if tokens.expiry.timeIntervalSince(now()) > 60 {
            return tokens.accessToken
        }

        let form = [
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ]
        let (data, status) = try await postForm(Self.tokenEndpoint, form: form)
        if let error = Self.classify(status: status, body: data) { throw error }
        struct Resp: Codable {
            let access_token: String
            let expires_in: Double
            let refresh_token: String?
        }
        let resp: Resp
        do {
            resp = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw OAuthError.transport("unexpected token response: \(error.localizedDescription)")
        }
        tokens.accessToken = resp.access_token
        tokens.expiry = now().addingTimeInterval(resp.expires_in)
        if let rotated = resp.refresh_token { tokens.refreshToken = rotated }
        saveTokens(tokens, providerId: providerId)
        return tokens.accessToken
    }

    private func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        var req = URLRequest(url: Self.userinfoEndpoint)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OAuthError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OAuthError.transport("userinfo HTTP \(status)")
        }
        return try JSONDecoder().decode(UserInfo.self, from: data)
    }

    // MARK: - Form encoding

    /// Strict application/x-www-form-urlencoded encoder. URLComponents'
    /// percentEncodedQuery leaves "+" unescaped, which a receiving parser
    /// reads back as a space, silently corrupting any client_secret / code /
    /// refresh_token value containing "+". This encodes every key and value
    /// against a strict unreserved set (alphanumerics plus "-._~") only,
    /// percent-encoding everything else, and sorts by key for deterministic,
    /// testable output.
    static func formURLEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet(charactersIn: "-._~")
        allowed.formUnion(.alphanumerics)
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        return form.keys.sorted()
            .map { "\(encode($0))=\(encode(form[$0]!))" }
            .joined(separator: "&")
    }

    private func postForm(_ url: URL, form: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formURLEncoded(form).utf8)
        do {
            let (data, response) = try await session.data(for: req)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw OAuthError.transport(error.localizedDescription)
        }
    }
}

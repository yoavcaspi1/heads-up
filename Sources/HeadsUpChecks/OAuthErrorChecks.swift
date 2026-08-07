@testable import HeadsUpKit
import Foundation

private func body(_ error: String) -> Data {
    Data("{\"error\": \"\(error)\", \"error_description\": \"x\"}".utf8)
}

func oauthErrorTests() async {
    suite("OAuthErrorTests")

    await test("testInvalidGrantClassified") {
        try expectEqual(GoogleOAuth.classify(status: 400, body: body("invalid_grant")), .invalidGrant)
    }

    await test("testInvalidClientClassified") {
        try expectEqual(GoogleOAuth.classify(status: 401, body: body("invalid_client")), .invalidClient)
        try expectEqual(GoogleOAuth.classify(status: 400, body: body("unauthorized_client")), .invalidClient)
    }

    await test("testOtherHTTPErrorIsTransport") {
        let e = GoogleOAuth.classify(status: 500, body: Data())
        guard case .transport = e ?? .transport("") else {
            throw CheckFailure(message: "expected transport, got \(String(describing: e))")
        }
    }

    await test("testSuccessIsNil") {
        try expectNil(GoogleOAuth.classify(status: 200, body: Data()))
    }

    await test("testTokenSetPersistenceRoundTrip") {
        let secrets = InMemorySecretStore()
        let creds = GoogleCredentialsStore(secrets: secrets)
        creds.save(clientId: "id", clientSecret: "sec")
        let oauth = GoogleOAuth(credentials: creds, secrets: secrets)
        let tokens = TokenSet(accessToken: "at", refreshToken: "rt", expiry: Date(timeIntervalSince1970: 100))
        oauth.saveTokens(tokens, providerId: "google-1")
        try expectEqual(oauth.loadTokens(providerId: "google-1"), tokens)
        oauth.deleteTokens(providerId: "google-1")
        try expectNil(oauth.loadTokens(providerId: "google-1"))
    }

    await test("form encoding escapes plus and space") {
        try expectEqual(GoogleOAuth.formURLEncoded(["a b": "c+d", "k": "v"]), "a%20b=c%2Bd&k=v")
    }

    await test("form encoding percent-encodes reserved characters") {
        try expectEqual(GoogleOAuth.formURLEncoded(["k": "se=cr&et"]), "k=se%3Dcr%26et")
    }
}

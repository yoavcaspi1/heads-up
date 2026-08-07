@testable import HeadsUpKit
import Foundation

func accountsRegistryTests() async {
    suite("AccountsRegistryTests")

    func makeRegistry() -> GoogleAccountsRegistry {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headsup-test-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let creds = GoogleCredentialsStore(secrets: secrets)
        creds.save(clientId: "id", clientSecret: "sec")
        let oauth = GoogleOAuth(credentials: creds, secrets: secrets)
        return GoogleAccountsRegistry(directory: dir, oauth: oauth)
    }

    await test("testAddListRemovePersists") {
        let reg = makeRegistry()
        try expect(!reg.hasAccounts)
        reg.addAccountRecord(GoogleAccount(id: "a@x.com", email: "a@x.com", name: "A", providerId: "google-1"))
        try expect(reg.hasAccounts)
        try expectEqual(reg.listAccounts().map(\.id), ["a@x.com"])
        reg.removeAccount(id: "a@x.com")
        try expect(!reg.hasAccounts)
    }

    await test("testInvalidGrantMarksNeedsReconnect") {
        let reg = makeRegistry()
        let acct = GoogleAccount(id: "a@x.com", email: "a@x.com", name: "A", providerId: "google-1")
        reg.addAccountRecord(acct)
        reg.setTokenFetcher { _ in throw OAuthError.invalidGrant }
        let token = await reg.accessToken(for: acct)
        try expectNil(token)
        try expect(reg.anyAccountNeedsReconnect)
        try expect(reg.listAccounts()[0].needsReconnect)
        try expect(!reg.credentialsInvalid)
    }

    await test("testTransportErrorDoesNotFlag") {
        let reg = makeRegistry()
        let acct = GoogleAccount(id: "a@x.com", email: "a@x.com", name: "A", providerId: "google-1")
        reg.addAccountRecord(acct)
        reg.setTokenFetcher { _ in throw OAuthError.transport("offline") }
        let token = await reg.accessToken(for: acct)
        try expectNil(token)
        try expect(!reg.anyAccountNeedsReconnect)
    }

    await test("testInvalidClientSetsGlobalFlag") {
        let reg = makeRegistry()
        let acct = GoogleAccount(id: "a@x.com", email: "a@x.com", name: "A", providerId: "google-1")
        reg.addAccountRecord(acct)
        reg.setTokenFetcher { _ in throw OAuthError.invalidClient }
        _ = await reg.accessToken(for: acct)
        try expect(reg.credentialsInvalid)
        try expect(!reg.anyAccountNeedsReconnect)
        reg.resetCredentialsInvalid()
        try expect(!reg.credentialsInvalid)
    }

    await test("testSuccessClearsReconnectFlag") {
        let reg = makeRegistry()
        let acct = GoogleAccount(id: "a@x.com", email: "a@x.com", name: "A", providerId: "google-1")
        reg.addAccountRecord(acct)
        reg.setTokenFetcher { _ in throw OAuthError.invalidGrant }
        _ = await reg.accessToken(for: acct)
        try expect(reg.anyAccountNeedsReconnect)
        reg.setTokenFetcher { _ in "fresh-token" }
        let token = await reg.accessToken(for: acct)
        try expectEqual(token, "fresh-token")
        try expect(!reg.anyAccountNeedsReconnect)
    }
}

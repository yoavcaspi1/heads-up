@testable import HeadsUpKit
import Foundation

func secretStoreTests() async {
    suite("SecretStoreTests")

    await test("testInMemoryRoundTrip") {
        let store = InMemorySecretStore()
        try expectNil(store.data(for: "k"))
        store.set(Data("v".utf8), for: "k")
        try expectEqual(store.data(for: "k"), Data("v".utf8))
        store.delete("k")
        try expectNil(store.data(for: "k"))
    }

    await test("testCredentialsStore") {
        let creds = GoogleCredentialsStore(secrets: InMemorySecretStore())
        try expect(!creds.isConfigured)
        try expectNil(creds.credentials)
        creds.save(clientId: "id.apps.googleusercontent.com", clientSecret: "shhh")
        try expect(creds.isConfigured)
        try expectEqual(creds.credentials?.clientId, "id.apps.googleusercontent.com")
        creds.clear()
        try expect(!creds.isConfigured)
    }

    await test("testCredentialsSurviveNewInstanceOverSameStore") {
        let secrets = InMemorySecretStore()
        GoogleCredentialsStore(secrets: secrets).save(clientId: "a", clientSecret: "b")
        try expectEqual(GoogleCredentialsStore(secrets: secrets).credentials?.clientSecret, "b")
    }
}

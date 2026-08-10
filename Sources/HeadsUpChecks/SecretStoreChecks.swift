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

    await test("testMigrationMovesItemsAndClearsTheOldStore") {
        let old = InMemorySecretStore(), new = InMemorySecretStore()
        old.set(Data("secret".utf8), for: "google-client-credentials")
        old.set(Data("tok".utf8), for: "tokens-abc")
        migrateSecrets(keys: ["google-client-credentials", "tokens-abc", "never-existed"],
                       from: old, to: new)
        try expectEqual(new.data(for: "google-client-credentials"), Data("secret".utf8))
        try expectEqual(new.data(for: "tokens-abc"), Data("tok".utf8))
        try expectNil(old.data(for: "google-client-credentials"))
        try expectNil(old.data(for: "tokens-abc"))
    }

    await test("testMigrationNeverClobbersAValueAlreadyInTheNewStore") {
        let old = InMemorySecretStore(), new = InMemorySecretStore()
        old.set(Data("stale".utf8), for: "k")
        new.set(Data("current".utf8), for: "k")
        migrateSecrets(keys: ["k"], from: old, to: new)
        try expectEqual(new.data(for: "k"), Data("current".utf8))
        try expectNil(old.data(for: "k"))
    }

    await test("testMigrationIsIdempotent") {
        let old = InMemorySecretStore(), new = InMemorySecretStore()
        old.set(Data("v".utf8), for: "k")
        migrateSecrets(keys: ["k"], from: old, to: new)
        migrateSecrets(keys: ["k"], from: old, to: new)
        migrateSecrets(keys: [], from: old, to: new)
        try expectEqual(new.data(for: "k"), Data("v".utf8))
        try expectNil(old.data(for: "k"))
    }

    // Read-only Keychain probe against a service no one owns: proves the
    // enumeration the real migration is driven by works and returns nothing
    // (so the migration no-ops) without writing to the developer's Keychain.
    await test("testKeychainItemKeysEmptyForUnusedService") {
        let keys = KeychainSecretStore.itemKeys(inService: "com.eloryo.headsup.checks.unused")
        try expect(keys.isEmpty)
        try expect(KeychainSecretStore.defaultService == "com.eloryo.headsup")
        try expect(KeychainSecretStore.legacyService == "com.cedoreholdings.headsup")
    }
}

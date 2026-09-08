@testable import HeadsUpKit
import Foundation

/// Dictionary-backed SecretStore so these checks never touch the Keychain.
private final class MemorySecretStore: SecretStore {
    var items: [String: Data] = [:]
    func data(for key: String) -> Data? { items[key] }
    func set(_ data: Data, for key: String) { items[key] = data }
    func delete(_ key: String) { items[key] = nil }
}

func googleCredentialsStoreTests() async {
    suite("GoogleCredentialsStoreTests")

    let bundled = GoogleClientCredentials(clientId: "1-bundled.apps.googleusercontent.com", clientSecret: "GOCSPX-b")

    await test("testBundledFromInfoDictionary") {
        let info: [String: Any] = [
            GoogleCredentialsStore.bundledClientIdKey: " 1-bundled.apps.googleusercontent.com ",
            GoogleCredentialsStore.bundledClientSecretKey: "GOCSPX-b",
        ]
        try expectEqual(GoogleCredentialsStore.bundled(from: info), bundled)
        try expectNil(GoogleCredentialsStore.bundled(from: [:]))
        // build_app.sh leaves the keys out entirely when unset, but a blank
        // value must count as absent too.
        try expectNil(GoogleCredentialsStore.bundled(from: [
            GoogleCredentialsStore.bundledClientIdKey: "", GoogleCredentialsStore.bundledClientSecretKey: "x"]))
    }

    await test("testBundledClientUsedUntilUserPastesOwn") {
        let store = GoogleCredentialsStore(secrets: MemorySecretStore(), bundled: bundled)
        try expect(store.isConfigured)
        try expect(store.hasBundledClient)
        try expect(store.usesBundledClient)
        try expectEqual(store.credentials, bundled)
        try expectNil(store.customCredentials)

        store.save(clientId: " 2-own.apps.googleusercontent.com ", clientSecret: "GOCSPX-o ")
        try expect(!store.usesBundledClient)
        try expectEqual(store.credentials?.clientId, "2-own.apps.googleusercontent.com")
        try expectEqual(store.credentials?.clientSecret, "GOCSPX-o")

        // Removing the user's own client falls back to the bundled one
        // rather than leaving the app unconfigured.
        store.clear()
        try expect(store.usesBundledClient)
        try expectEqual(store.credentials, bundled)
    }

    await test("testNoBundledClientBehavesAsBefore") {
        let store = GoogleCredentialsStore(secrets: MemorySecretStore(), bundled: nil)
        try expect(!store.isConfigured)
        try expect(!store.hasBundledClient)
        try expect(!store.usesBundledClient)
        store.save(clientId: "2-own.apps.googleusercontent.com", clientSecret: "s")
        try expect(store.isConfigured)
        store.clear()
        try expect(!store.isConfigured)
    }
}

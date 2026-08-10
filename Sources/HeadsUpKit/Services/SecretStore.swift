import Foundation
import Security

protocol SecretStore {
    func data(for key: String) -> Data?
    func set(_ data: Data, for key: String)
    func delete(_ key: String)
}

/// Moves `keys` from `old` into `new`. Copies only what `new` does not
/// already hold, so a value written since a previous partial run is never
/// clobbered, and drops the old copy only once the new one reads back: an
/// interrupted run leaves the original in place and simply retries, rather
/// than losing a secret. Idempotent, and a no-op on an empty key list.
func migrateSecrets(keys: [String], from old: SecretStore, to new: SecretStore) {
    for key in keys {
        guard let value = old.data(for: key) else { continue }
        if new.data(for: key) == nil { new.set(value, for: key) }
        if new.data(for: key) != nil { old.delete(key) }
    }
}

/// Dictionary-backed store for unit tests.
final class InMemorySecretStore: SecretStore {
    private var storage: [String: Data] = [:]
    func data(for key: String) -> Data? { storage[key] }
    func set(_ data: Data, for key: String) { storage[key] = data }
    func delete(_ key: String) { storage[key] = nil }
}

/// Generic-password Keychain store scoped to one service name.
final class KeychainSecretStore: SecretStore {
    private let service: String
    init(service: String) { self.service = service }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func data(for key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func set(_ data: Data, for key: String) {
        let query = baseQuery(key)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("HeadsUp Keychain set failed for %@: %d", key, addStatus)
            }
        } else if updateStatus != errSecSuccess {
            NSLog("HeadsUp Keychain set failed for %@: %d", key, updateStatus)
        }
    }

    func delete(_ key: String) {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("HeadsUp Keychain delete failed for %@: %d", key, status)
        }
    }

    // MARK: - Service rename

    /// Keychain service the app stores its secrets under, and the name it
    /// used before the group's domain moved to eloryo.com. Existing installs
    /// still hold their items under the old one until they next launch.
    static let defaultService = "com.eloryo.headsup"
    static let legacyService = "com.cedoreholdings.headsup"

    /// Account names of every generic-password item filed under `service`.
    /// Attribute-only query: it reads no secret material, so it never
    /// triggers a Keychain access prompt even for items this app does not
    /// own, which keeps the migration probe below silent and cheap.
    static func itemKeys(inService service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// One-time, silent adoption of everything still filed under a previous
    /// service name. Enumerates rather than working from a fixed key list,
    /// because the per-account token keys (`tokens-<providerId>`) are only
    /// known at runtime. Runs on every launch and costs one attribute query
    /// once there is nothing left to move.
    func migrateItems(fromService oldService: String) {
        let keys = Self.itemKeys(inService: oldService)
        guard !keys.isEmpty else { return }
        migrateSecrets(keys: keys, from: KeychainSecretStore(service: oldService), to: self)
        NSLog("HeadsUp Keychain: adopted %d item(s) from service %@", keys.count, oldService)
    }
}

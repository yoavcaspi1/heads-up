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

    /// True for the statuses that mean "the item is there, but this build is
    /// not on its access-control list" rather than "no such item". macOS
    /// answers a denied read with `errSecAuthFailed` once the user dismisses
    /// the access prompt, and with `errSecInteractionNotAllowed` when no
    /// prompt could be shown at all.
    private static func isAccessDenied(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
    }

    /// Advice printed alongside every access-control failure. See the
    /// "Keychain access prompts" section of the README for the background.
    private static let accessDeniedHint =
        "the item's Keychain ACL names an earlier code identity of this app; "
        + "answer the macOS prompt with Always Allow, or delete the item in "
        + "Keychain Access to start clean"

    func data(for key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            // Absence is the ordinary case (first run, or an account that has
            // never been connected) and stays quiet. A denial is not: it looks
            // identical to absence from here, and the caller will react by
            // asking the user to authenticate again, so say why in the log.
            if Self.isAccessDenied(status) {
                NSLog("HeadsUp Keychain read denied for %@ in %@ (%d) - %@",
                      key, service, status, Self.accessDeniedHint)
            } else if status != errSecItemNotFound {
                NSLog("HeadsUp Keychain read failed for %@ in %@: %d", key, service, status)
            }
            return nil
        }
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
            return
        }
        if updateStatus != errSecSuccess {
            NSLog("HeadsUp Keychain set failed for %@: %d", key, updateStatus)
            return
        }
        // A write can land in an item this build is not allowed to read back:
        // `SecItemUpdate` needs no decrypt authorization, so it succeeds even
        // against a stale access-control list, while `SecItemCopyMatching`
        // does not. Left undetected that produces the worst failure mode
        // available here - re-authentication that reports success, stores a
        // good token, and still comes up empty on the next launch, forever.
        // Neither deleting nor re-adding the item can clear this from code
        // (both are refused for the same reason), so the only honest response
        // is to name it in the log; the fix is a user action, once.
        if !verifyReadBack(data, for: key) {
            NSLog("HeadsUp Keychain wrote %@ but cannot read it back - %@",
                  key, Self.accessDeniedHint)
        }
    }

    /// Reads `key` straight back and compares. Silent and cheap when the ACL
    /// is intact, which is every case except the launch after a code-identity
    /// change; a mismatch (rather than a denial) would mean a second writer.
    private func verifyReadBack(_ written: Data, for key: String) -> Bool {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let stored = result as? Data else { return false }
        return stored == written
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

import Foundation
import Security

protocol SecretStore {
    func data(for key: String) -> Data?
    func set(_ data: Data, for key: String)
    func delete(_ key: String)
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
}

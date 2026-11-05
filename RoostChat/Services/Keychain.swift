import Foundation
import Security

/// Passwords live only in the Keychain, never in SwiftData or defaults.
enum Keychain {
    private static let service = "roostchat.xmpp"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        // Readable after first unlock so reconnects work; never synced or backed up off-device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    static func accountKey(_ jid: String) -> String { "account:\(jid)" }
    static func roomKey(account: String, room: String) -> String { "room:\(account)|\(room)" }
}

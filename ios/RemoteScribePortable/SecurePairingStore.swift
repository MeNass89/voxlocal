import Foundation
import Security

/// Keychain failures are surfaced to the caller; a failed purge is never success.
enum SecurePairingStore {
    private static let service = "com.voxlocal.remotescribe.portable"
    private static let account = "pairing-code"

    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Trousseau indisponible (code \(status))."
        }
    }

    static func load() throws -> String {
        guard let data = try loadData(account: account) else { return "" }
        guard let value = String(data: data, encoding: .utf8) else { throw StoreError(status: errSecDecode) }
        return value
    }

    static func loadData(account: String) throws -> Data? {
        var query = lookup(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data else { throw StoreError(status: errSecDecode) }
        return data
    }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try deleteData(account: account); return }
        try saveData(Data(trimmed.utf8), account: account, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    static func saveData(_ data: Data, account: String, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        let query = lookup(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessibility]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            try check(SecItemAdd(insertion as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func deleteData(account: String) throws {
        let status = SecItemDelete(lookup(account: account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func lookup(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }
}

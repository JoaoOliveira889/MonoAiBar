import Foundation
import Security

enum Keychain {
    struct Item: Sendable {
        let secret: String
        let account: String?
    }

    static func read(service: String, account: String? = nil) -> Item? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.credentials.debug("keychain read failed for \(service, privacy: .public): \(status)")
            }
            return nil
        }

        guard let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let secret = String(data: data, encoding: .utf8) else { return nil }

        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return Item(secret: trimmed, account: attributes[kSecAttrAccount as String] as? String ?? account)
    }

    @discardableResult
    static func write(service: String, account: String, secret: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else {
            Log.credentials.error("keychain update failed for \(service, privacy: .public): \(updateStatus)")
            return false
        }

        var insert = identity
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecAttrSynchronizable as String] = false
        insert[kSecAttrLabel as String] = "MonoAiBar — \(service)"

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.credentials.error("keychain add failed for \(service, privacy: .public): \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func delete(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

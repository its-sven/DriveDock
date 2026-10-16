import Foundation
import Security

/// Stores one password per connection in the login keychain.
enum Keychain {
    private static let service = "DriveDock"

    private static func baseQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func password(for id: UUID) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for id: UUID) -> Bool {
        var query = baseQuery(id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func setPassword(_ password: String, for id: UUID, label: String) -> Bool {
        delete(for: id)
        var query = baseQuery(id)
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrLabel as String] = "DriveDock – \(label)"
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("DriveDock: keychain write failed (%d)", status)
        }
        return status == errSecSuccess
    }

    static func delete(for id: UUID) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }
}

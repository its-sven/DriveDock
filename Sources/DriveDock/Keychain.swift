import Foundation
import Security

/// Profile passwords, kept in ONE login-keychain item ("DriveDock" / "passwords") as JSON.
///
/// Why a single item: without an Apple Team ID, macOS ties keychain access to the code hash
/// of the binary (the item's partition list), so after every update it asks once per item.
/// One item means one question per update instead of one per server.
///
/// All access runs one call at a time on a private queue – two calls waiting on the same
/// keychain prompt would otherwise both block – and the passwords are cached in memory, so
/// reconnects after sleep or network changes never touch the keychain.
///
/// Versions before 0.5.2 stored one item per profile (account = profile UUID). Such a
/// password is moved into the shared item the first time it is needed; the old item stays
/// untouched (deleting it could trigger another prompt) and is ignored from then on.
///
/// Every function blocks while macOS shows a keychain prompt: never call them on the main thread.
enum Keychain {
    enum Lookup {
        case found(String)
        case missing
        /// Reading failed, e.g. the user denied the keychain prompt.
        case unavailable
    }

    private static let service = "DriveDock"
    private static let vaultAccount = "passwords"
    private static let queue = DispatchQueue(label: "DriveDock.keychain")

    // State below is only touched on `queue`.
    private static var cache: [String: String]?
    /// Set when the shared item couldn't be read; no new prompt until a user action.
    private static var readFailed = false

    // MARK: - API

    /// `allowPrompt: false` (automatic reconnects) doesn't ask again after the user denied access.
    static func password(for id: UUID, allowPrompt: Bool = true) -> Lookup {
        queue.sync {
            guard let passwords = loadVault(allowPrompt: allowPrompt) else {
                // The shared item is unreadable. Reading the fallback item could prompt as well,
                // so only try it when asking is allowed.
                if allowPrompt, let fallback = readItem(account: id.uuidString).value { return .found(fallback) }
                return .unavailable
            }
            if let password = passwords[id.uuidString] { return .found(password) }
            switch readItem(account: id.uuidString) {
            case .found(let legacy):
                var updated = passwords
                updated[id.uuidString] = legacy
                writeVault(updated)
                return .found(legacy)
            case .missing:
                return .missing
            case .unavailable:
                return .unavailable
            }
        }
    }

    /// Saves the password. Returns false if it couldn't be stored at all.
    @discardableResult
    static func setPassword(_ password: String, for id: UUID) -> Bool {
        queue.sync {
            // Saving is a user action, so asking again after a denied prompt is fine.
            guard var passwords = loadVault(allowPrompt: true) else {
                // Never overwrite a shared item we couldn't read – it holds the other
                // profiles' passwords. Store this one on its own instead.
                return writeItem(account: id.uuidString, data: Data(password.utf8))
            }
            passwords[id.uuidString] = password
            return writeVault(passwords)
        }
    }

    static func delete(for id: UUID) {
        queue.sync {
            if var passwords = loadVault(allowPrompt: true), passwords.removeValue(forKey: id.uuidString) != nil {
                writeVault(passwords)
            }
            SecItemDelete(query(account: id.uuidString) as CFDictionary)
        }
    }

    /// Whether a per-profile item from an older version exists – attributes only, never a prompt.
    static func legacyItemExists(for id: UUID) -> Bool {
        queue.sync {
            var q = query(account: id.uuidString)
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
        }
    }

    // MARK: - Shared item

    /// The decoded passwords, or nil if the item exists but can't be read.
    private static func loadVault(allowPrompt: Bool) -> [String: String]? {
        if let cache { return cache }
        if readFailed, !allowPrompt { return nil }
        switch readItem(account: vaultAccount) {
        case .found(let json):
            let decoded = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
            cache = decoded
            readFailed = false
            return decoded
        case .missing:
            cache = [:]
            readFailed = false
            return [:]
        case .unavailable:
            readFailed = true
            return nil
        }
    }

    @discardableResult
    private static func writeVault(_ passwords: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(passwords) else { return false }
        let ok = writeItem(account: vaultAccount, data: data)
        if ok { cache = passwords }
        return ok
    }

    // MARK: - Items

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readItem(account: String) -> Lookup {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return .unavailable }
            return .found(text)
        case errSecItemNotFound:
            return .missing
        default:
            NSLog("DriveDock: keychain read failed (%d)", status)
            return .unavailable
        }
    }

    /// Updates the item in place (keeps its access rules), or adds it.
    private static func writeItem(account: String, data: Data) -> Bool {
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query(account: account) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = query(account: account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = account == vaultAccount ? "DriveDock" : "DriveDock (\(account))"
            add[kSecAttrDescription as String] = "DriveDock server passwords"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("DriveDock: keychain write failed (%d)", status)
        }
        return status == errSecSuccess
    }
}

private extension Keychain.Lookup {
    var value: String? {
        if case .found(let password) = self { return password }
        return nil
    }
}

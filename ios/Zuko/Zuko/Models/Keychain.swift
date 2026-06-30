import Foundation
import Security

/// Thin wrapper over the iOS Keychain shared by the app's two secret stores:
/// the saved connection tickets ([`ConnectionKeychain`]) and the client
/// identity seed ([`ClientIdentity`]). Centralises the `SecItem*` boilerplate,
/// the bundle-scoped `service` id, and the
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` accessibility so both
/// stores stay consistent (hardware-backed, excluded from unencrypted backups,
/// not synced to other devices).
///
/// All items are `kSecClassGenericPassword`, keyed by the fixed `service` plus
/// a per-store `account`.
enum Keychain {
    /// Bundle-scoped service id so a future sibling app can't read these items.
    static let service = "dev.adonm.zuko"

    enum KeychainError: LocalizedError {
        /// A matching item existed but its data wasn't the expected `Data`.
        case unexpectedItemType
        /// Any other non-success `OSStatus` from the Security framework.
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedItemType:
                return "Keychain returned an unexpected item type."
            case .status(let status):
                return "Keychain operation failed (OSStatus \(status))."
            }
        }
    }

    /// Read the data for `account`, or `nil` when no such item exists (so the
    /// caller can tell "first launch" from a real error).
    static func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpectedItemType }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Upsert `data` for `account`: add it, or update it in place if present.
    static func upsert(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.status(updateStatus) }
        default:
            throw KeychainError.status(addStatus)
        }
    }

    /// Add `data` for `account` only if absent. Returns `false` (rather than
    /// throwing) when an item already exists, so a create-once caller can
    /// re-read the race winner instead of clobbering it.
    @discardableResult
    static func addIfAbsent(_ data: Data, account: String) throws -> Bool {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw KeychainError.status(status)
        }
    }

    /// Delete the item for `account`. A missing item is a successful no-op.
    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

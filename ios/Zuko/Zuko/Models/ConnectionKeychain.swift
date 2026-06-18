import Foundation
import Security

/// Stores the user's saved connections in the iOS Keychain.
///
/// Every `Connection.ticket` is a bearer token that grants shell access on its
/// host, so the whole collection is persisted as a single Keychain item
/// (`kSecClassGenericPassword`) rather than in `UserDefaults` — which lives in
/// an on-disk plist decrypted after first unlock and is included in unencrypted
/// backups. The Keychain uses hardware-backed key protection (Secure Enclave on
/// supported devices) and is excluded from unencrypted backups by default.
///
/// The Keychain item is keyed by a fixed `service` / `account` pair; the
/// entire JSON-encoded `[Connection]` array is the item's data. This keeps the
/// store a single source of truth — there's no per-connection ticket/metadata
/// split to keep in sync.
///
/// Errors are surfaced (not silently dropped) so the caller can decide whether
/// to fail the operation or fall back to in-memory state.
enum ConnectionKeychain {
    /// Keychain item service. Tied to the bundle id so a future sibling app
    /// can't read these items.
    private static let service = "dev.adonm.zuko"

    /// Keychain item account. A single account holds the whole collection; if
    /// we ever split per-connection, each `Connection.id` would become an
    /// account here.
    private static let account = "connections"

    /// Load the saved connections, returning `nil` if no item exists yet (so
    /// the caller can distinguish "first launch" from a real decode error).
    static func load() throws -> [Connection]? {
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
            guard let data = item as? Data else { return nil }
            return try JSONDecoder().decode([Connection].self, from: data)
        case errSecItemNotFound:
            // No item yet — distinct from a decode failure so the caller can
            // tell first-launch from corruption.
            return nil
        default:
            throw KeychainError.keychain(status: status)
        }
    }

    /// Upsert the saved connections into the Keychain. Adds the item on first
    /// launch; updates it in place on every subsequent call.
    static func save(_ connections: [Connection]) throws {
        let data = try JSONEncoder().encode(connections)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Try to add first; if a duplicate exists, fall back to an in-place
        // update. SecItemAdd returns errSecDuplicateItem in that case.
        var addAttrs = attrs
        addAttrs[kSecValueData as String] = data
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(attrs as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.keychain(status: updateStatus)
            }
            return
        default:
            throw KeychainError.keychain(status: addStatus)
        }
    }

    /// Delete every stored connection. Used by tests and (eventually) a
    /// "clear all" UI action.
    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is a successful no-op delete.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.keychain(status: status)
        }
    }

    enum KeychainError: LocalizedError {
        case keychain(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "Keychain operation failed (OSStatus \(status))."
            }
        }
    }
}

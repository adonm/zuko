import Foundation

/// Stores the user's saved connections in the iOS Keychain (via [`Keychain`]).
///
/// A `Connection.ticket` contains sensitive host dial information. Shell access
/// also requires this install's authorized client token, but connection state
/// still belongs in a single Keychain item rather than in `UserDefaults` —
/// which lives in an on-disk plist decrypted after first unlock and is included
/// in unencrypted backups. The Keychain uses
/// hardware-backed key protection (Secure Enclave on supported devices) and is
/// excluded from unencrypted backups by default.
///
/// The whole JSON-encoded `[Connection]` array is one Keychain item keyed by a
/// fixed `account`; there's no per-connection ticket/metadata split to keep in
/// sync. Errors are surfaced (not silently dropped) so the caller can decide
/// whether to fail the operation or fall back to in-memory state.
enum ConnectionKeychain {
    /// A single account holds the whole collection.
    private static let account = "connections"

    /// Load the saved connections, returning `nil` if no item exists yet (so
    /// the caller can distinguish "first launch" from a real decode error).
    static func load() throws -> [Connection]? {
        guard let data = try Keychain.read(account: account) else { return nil }
        return try JSONDecoder().decode([Connection].self, from: data)
    }

    /// Upsert the saved connections into the Keychain.
    static func save(_ connections: [Connection]) throws {
        let data = try JSONEncoder().encode(connections)
        try Keychain.upsert(data, account: account)
    }

    /// Delete every stored connection. Used by tests and a future "clear all".
    static func delete() throws {
        try Keychain.delete(account: account)
    }
}

import CryptoKit
import Foundation
import IrohLib
import Security
import ZukoWire

/// Stable per-install client identity used to derive host-scoped reattach
/// tokens for `zuko host`.
///
/// The Rust CLI stores `~/.config/zuko/client_key` and derives a deterministic
/// 16-byte token from `(client secret, host id)`. iOS doesn't need a dialable
/// Iroh identity for this — it only needs stable, private entropy — so we keep
/// a 32-byte random seed in the Keychain and hash it with the host id parsed
/// from the saved ticket. That gives the same App Store app install the same
/// PTY across reconnects and fresh launches, while different hosts still get
/// unrelated tokens.
enum ClientIdentity {
    /// Keychain account for the identity seed (the shared `service` lives in
    /// [`Keychain`]). Distinct from the connections account so the two never
    /// collide.
    private static let account = "client-identity-v1"
    private static let seedLength = 32

    static func sessionToken(for ticket: EndpointTicket) throws -> Data {
        let seed = try loadOrCreateSeed()
        return sessionToken(for: ticket, seed: seed)
    }

    static func sessionToken(for ticket: EndpointTicket, seed: Data) -> Data {
        let hostID = ticket.endpointAddr().id().description
        var hasher = SHA256()
        hasher.update(data: Data("zuko-ios-session-token-v1".utf8))
        hasher.update(data: seed)
        hasher.update(data: Data(hostID.utf8))
        let digest = Data(hasher.finalize())
        return digest.prefix(Wire.sessionTokenLength)
    }

    private static func loadOrCreateSeed() throws -> Data {
        if let existing = try loadSeed() {
            return existing
        }
        let seed = try randomSeed()
        // Create-once: if a concurrent launch already wrote a seed, keep theirs
        // (re-read) rather than clobbering it — otherwise the two installs would
        // derive different reattach tokens for the same host.
        if try Keychain.addIfAbsent(seed, account: account) {
            return seed
        }
        if let existing = try loadSeed() {
            return existing
        }
        // Add reported a duplicate but the re-read found nothing — should be
        // impossible (the item must exist to collide), so surface it.
        throw IdentityError.invalidSeed
    }

    private static func loadSeed() throws -> Data? {
        guard let data = try Keychain.read(account: account) else { return nil }
        guard data.count == seedLength else { throw IdentityError.invalidSeed }
        return data
    }

    private static func randomSeed() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: seedLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Keychain.KeychainError.status(status)
        }
        return Data(bytes)
    }

    enum IdentityError: LocalizedError {
        case invalidSeed

        var errorDescription: String? {
            switch self {
            case .invalidSeed:
                return "Stored client identity is malformed."
            }
        }
    }
}

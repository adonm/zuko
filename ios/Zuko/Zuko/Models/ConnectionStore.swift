import Foundation
import IrohLib
import os

/// Persists the user's saved connections in the iOS Keychain (see
/// [`ConnectionKeychain`]). Keeps the most recent `maxConnections` so the list
/// stays tidy.
///
/// On first launch after the Keychain migration, any connections previously
/// stored in `UserDefaults` (under the v1 key) are moved into the Keychain and
/// the legacy entry is deleted — so a user upgrading from an earlier build
/// keeps their saved hosts without re-pasting tickets.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [Connection] = []

    /// Legacy `UserDefaults` key from before the Keychain migration. Kept only
    /// long enough to migrate existing users; new writes never touch it.
    private static let legacyStorageKey = "dev.adonm.zuko.connections.v1"
    private static let maxConnections = 12
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.adonm.zuko", category: "ConnectionStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.connections = load()
    }

    /// Validates + normalises a ticket and, if it parses, saves it.
    /// Throws a human-readable failure when the ticket is bad.
    @discardableResult
    func add(label: String, ticket rawTicket: String) throws -> Connection {
        let ticket = rawTicket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ticket.isEmpty else {
            throw AddError.empty
        }
        // Validate against Iroh so we never store garbage.
        do {
            _ = try EndpointTicket.fromString(str: ticket).endpointAddr()
        } catch {
            throw AddError.invalid("That doesn't look like a ticket: \(error.localizedDescription)")
        }

        let connection = Connection(label: label, ticket: ticket)
        // De-dupe by node identity: if we already have this exact ticket, just
        // bump it to the top rather than keeping a stale copy.
        connections.removeAll { $0.ticket == connection.ticket }
        connections.insert(connection, at: 0)
        if connections.count > Self.maxConnections {
            connections = Array(connections.prefix(Self.maxConnections))
        }
        save()
        return connection
    }

    enum AddError: LocalizedError {
        case empty
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "Paste the ticket your host printed."
            case .invalid(let message): return message
            }
        }
    }

    func remove(at offsets: IndexSet) {
        connections.remove(atOffsets: offsets)
        save()
    }

    func remove(_ connection: Connection) {
        connections.removeAll { $0.id == connection.id }
        save()
    }

    // MARK: - Persistence

    /// Load connections from the Keychain, migrating from `UserDefaults` on the
    /// first launch after upgrade. Returns `[]` only when there is genuinely
    /// nothing stored — a decode failure is logged (not silently dropped) and
    /// also returns `[]`, but the corrupted blob stays on disk so the user (or
    /// a future versioned migration) can recover it; we deliberately do not
    /// call `save()` on an empty result of a failed decode, so the next
    /// user-initiated add/remove is what eventually replaces the bad blob.
    private func load() -> [Connection] {
        // Primary path: read from the Keychain.
        do {
            if let decoded = try ConnectionKeychain.load() {
                return decoded
            }
        } catch {
            // Distinguish decode failures (Actionable: schema changed, data
            // rotted) from Keychain I/O failures so the user can debug via
            // Console.app.
            logger.error("Keychain load failed; keeping on-disk blob for recovery: \(String(describing: error))")
        }

        // Migration path: an earlier build wrote to UserDefaults. If the
        // Keychain is empty but a legacy blob exists, move it over and clear
        // the legacy entry. A failed decode here is also logged, not silent.
        guard let data = defaults.data(forKey: Self.legacyStorageKey) else {
            return []
        }
        do {
            let decoded = try JSONDecoder().decode([Connection].self, from: data)
            try? ConnectionKeychain.save(decoded)
            defaults.removeObject(forKey: Self.legacyStorageKey)
            return decoded
        } catch {
            logger.error("Legacy UserDefaults blob failed to decode; leaving it in place for recovery: \(String(describing: error))")
            return []
        }
    }

    private func save() {
        do {
            try ConnectionKeychain.save(connections)
        } catch {
            // The Keychain write failed (disk full, item locked, etc.). Surface
            // it via os_log so the user has a chance to notice; the in-memory
            // list still reflects their intent for this session.
            logger.error("Failed to persist connections to Keychain: \(String(describing: error))")
        }
    }
}

/// Short, recognisable id for a connection (first 8 hex chars of the node id),
/// derived lazily from the stored ticket. Falls back to a ticket prefix.
func shortNodeId(for connection: Connection) -> String {
    if let addr = try? EndpointTicket.fromString(str: connection.ticket).endpointAddr() {
        let full = addr.id().description
        return String(full.prefix(8))
    }
    return String(connection.ticket.prefix(8))
}

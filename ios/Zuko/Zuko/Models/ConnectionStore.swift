import Foundation
import IrohLib
import os

/// Persists the user's saved connections in the iOS Keychain (see
/// [`ConnectionKeychain`]). Keeps the most recent `maxConnections` so the list
/// stays tidy.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [Connection] = []

    /// `UserDefaults` key for a pre-Keychain build. Read once on load to
    /// migrate existing users; never written.
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

    /// Update the saved session id on a connection (v0.4+ resume). The host
    /// assigns the id on connect; persisting it lets a later app launch
    /// resume the same session. Best-effort: a Keychain failure is logged,
    /// not thrown — the live session still works without the persisted id.
    func updateSessionID(_ sessionID: Data?, for connection: Connection) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else {
            return
        }
        // Skip the write if nothing changed (the callback fires often).
        guard connections[idx].lastSessionID != sessionID else { return }
        connections[idx].lastSessionID = sessionID
        save()
    }

    // MARK: - Persistence

    /// Load connections from the Keychain, migrating from `UserDefaults` on
    /// first launch if a pre-Keychain blob exists. Returns `[]` only when
    /// there's genuinely nothing stored — a decode failure is logged (not
    /// silently dropped) and the corrupted blob stays on disk for recovery;
    /// `save()` is not called on the empty result of a failed decode.
    private func load() -> [Connection] {
        // Primary path: read from the Keychain.
        do {
            if let decoded = try ConnectionKeychain.load() {
                return decoded
            }
        } catch {
            // Distinguish decode failures (actionable: schema changed, data
            // rotted) from Keychain I/O failures so the user can debug via
            // Console.app.
            logger.error("Keychain load failed; keeping on-disk blob for recovery: \(String(describing: error))")
        }

        // Migration: a pre-Keychain build wrote to UserDefaults. If the
        // Keychain is empty but a legacy blob exists, move it over and clear
        // the legacy entry. The legacy entry is only deleted *after* the
        // Keychain write succeeds — otherwise a transient Keychain failure
        // (device locked, item locked, quota, etc.) would silently and
        // permanently lose every saved connection. A failed migration is
        // retried on the next launch instead.
        guard let data = defaults.data(forKey: Self.legacyStorageKey) else {
            return []
        }
        let decoded: [Connection]
        do {
            decoded = try JSONDecoder().decode([Connection].self, from: data)
        } catch {
            logger.error("Legacy UserDefaults blob failed to decode; leaving it in place for recovery: \(String(describing: error))")
            return []
        }
        do {
            try ConnectionKeychain.save(decoded)
        } catch {
            logger.error("Migration to Keychain failed; keeping legacy entry for retry on next launch: \(String(describing: error))")
            // Return the decoded list so the current session still works,
            // but leave the legacy blob on disk so we retry next time.
            return decoded
        }
        defaults.removeObject(forKey: Self.legacyStorageKey)
        return decoded
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

import Foundation
import IrohLib
import Observation
import os

/// Persists the user's saved connections in the iOS Keychain (see
/// [`ConnectionKeychain`]). Keeps the most recent `maxConnections` so the list
/// stays tidy.
///
/// Uses the Swift 5.9+ `@Observable` macro (iOS 17+) — `connections` is the
/// only UI-facing state. Internal state (UserDefaults handle, logger, max
/// count) is marked `@ObservationIgnored` so writes to it don't notify, and
/// reads of e.g. `logger` from within a view body don't subscribe the view
/// to irrelevant changes.
@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []

    /// `UserDefaults` key for a pre-Keychain build. Read once on load to
    /// migrate existing users; never written.
    @ObservationIgnored private static let legacyStorageKey = "dev.adonm.zuko.connections.v1"
    @ObservationIgnored private static let maxConnections = 12
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "dev.adonm.zuko", category: "ConnectionStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.connections = load()
    }

    /// Validates + normalises a ticket and persists the complete candidate
    /// collection before publishing it to the UI. A Keychain failure therefore
    /// cannot produce a host that appears saved until the next app launch.
    @discardableResult
    func add(
        label: String,
        ticket rawTicket: String,
        authorizedClientLabel: String? = nil
    ) throws -> Connection {
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

        var candidate = connections
        let existing = candidate.first { sameHost($0.ticket, ticket) }
        let connection = Connection(
            id: existing?.id ?? UUID(),
            label: label,
            ticket: ticket,
            addedAt: existing?.addedAt ?? .now,
            lastConnectedAt: existing?.lastConnectedAt,
            authorizedClientLabel: authorizedClientLabel ?? existing?.authorizedClientLabel
        )
        // Re-pairing the same node updates its addresses/label while preserving
        // its local identity and history, then promotes it to the front.
        candidate.removeAll { sameHost($0.ticket, connection.ticket) }
        candidate.insert(connection, at: 0)
        if candidate.count > Self.maxConnections {
            candidate = Array(candidate.prefix(Self.maxConnections))
        }
        try persist(candidate, action: "save the host")
        connections = candidate
        return connection
    }

    enum AddError: LocalizedError {
        case empty
        case invalid(String)
        case invalidLabel
        case persistence(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "The host returned empty connection information. Pair again."
            case .invalid(let message): return message
            case .invalidLabel: return "Enter a name for this host."
            case .persistence(let message): return message
            }
        }
    }

    func remove(at offsets: IndexSet) throws {
        let ids = Set(offsets.compactMap { index in
            connections.indices.contains(index) ? connections[index].id : nil
        })
        try remove(ids: ids)
    }

    func remove(_ connection: Connection) throws {
        try remove(ids: [connection.id])
    }

    func remove(ids: Set<Connection.ID>) throws {
        guard !ids.isEmpty else { return }
        let candidate = connections.filter { !ids.contains($0.id) }
        try persist(candidate, action: ids.count == 1 ? "forget the host" : "forget the hosts")
        connections = candidate
    }

    @discardableResult
    func rename(_ connectionID: Connection.ID, to rawLabel: String) throws -> Connection {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw AddError.invalidLabel }
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else {
            throw AddError.invalid("That host is no longer saved.")
        }
        var candidate = connections
        candidate[index].label = label
        try persist(candidate, action: "rename the host")
        connections = candidate
        return candidate[index]
    }

    /// Record a successful connection and promote the host to the front. This
    /// mirrors the CLI's recent-host ordering and is transactional for the same
    /// reason as add/remove: visible metadata must match the Keychain.
    func markConnected(_ connectionID: Connection.ID, at date: Date = .now) throws {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        var candidate = connections
        var connection = candidate.remove(at: index)
        connection.lastConnectedAt = date
        candidate.insert(connection, at: 0)
        try persist(candidate, action: "update the host")
        connections = candidate
    }

    // MARK: - Persistence

    /// Load connections from the Keychain, migrating from `UserDefaults` on
    /// first launch if a pre-Keychain blob exists. Returns `[]` only when
    /// there's genuinely nothing stored — a decode failure is logged (not
    /// silently dropped) and the corrupted blob stays on disk for recovery;
    /// `persist(_:)` is not called on the empty result of a failed decode.
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

    private func persist(_ candidate: [Connection], action: String) throws {
        do {
            try ConnectionKeychain.save(candidate)
        } catch {
            let detail = error.localizedDescription
            logger.error("Failed to \(action) in Keychain: \(String(describing: error))")
            throw AddError.persistence("Couldn't \(action) in the Keychain. \(detail)")
        }
    }

    private func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = hostNodeID(forTicket: lhs),
              let right = hostNodeID(forTicket: rhs)
        else { return lhs == rhs }
        return left == right
    }
}

func hostNodeID(forTicket ticket: String) -> String? {
    try? EndpointTicket.fromString(str: ticket).endpointAddr().id().description
}

/// Short, recognisable id for a connection (first 8 hex chars of the node id),
/// derived lazily from the stored ticket. Falls back to a ticket prefix.
func shortNodeId(for connection: Connection) -> String {
    if let full = hostNodeID(forTicket: connection.ticket) {
        return String(full.prefix(8))
    }
    return String(connection.ticket.prefix(8))
}

import Foundation
import IrohLib

/// Persists the user's saved connections in UserDefaults. Keeps the most recent
/// `maxConnections` so the list stays tidy.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [Connection] = []

    private static let storageKey = "dev.adonm.zuko.connections.v1"
    private static let maxConnections = 12
    private let defaults: UserDefaults

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

    private func load() -> [Connection] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Connection].self, from: data)
        else { return [] }
        return decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: Self.storageKey)
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

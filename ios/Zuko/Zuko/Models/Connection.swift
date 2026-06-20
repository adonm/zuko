import Foundation

/// A saved host the user can dial back into. The `ticket` is an Iroh endpoint
/// ticket; it encodes a stable node id (because the host persists its secret
/// key) plus last-known addresses, so saved connections keep working across
/// host restarts — Iroh's discovery resolves the current address on dial.
///
/// `lastSessionID` is the host-assigned session id from the most recent
/// session on this host (v0.4+). Sending it in HELLO on the next connect lets
/// the host resume that session's PTY + scrollback — even across an app
/// relaunch. It's optional + decoded with `decodeIfPresent` so pre-v0.4
/// keychain entries (which lack the field) still load cleanly.
struct Connection: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var ticket: String
    var addedAt: Date
    var lastSessionID: Data?

    init(id: UUID = UUID(), label: String, ticket: String, addedAt: Date = .now, lastSessionID: Data? = nil) {
        self.id = id
        self.label = label.isEmpty ? "Host" : label
        self.ticket = ticket
        self.addedAt = addedAt
        self.lastSessionID = lastSessionID
    }

    // Stable Codable keys so adding `lastSessionID` doesn't break entries
    // written by older builds (the field is simply absent there → nil).
    enum CodingKeys: String, CodingKey {
        case id, label, ticket, addedAt, lastSessionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        ticket = try c.decode(String.self, forKey: .ticket)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        // Pre-v0.4 entries have no lastSessionID — nil is the right value.
        lastSessionID = try c.decodeIfPresent(Data.self, forKey: .lastSessionID)
    }
}

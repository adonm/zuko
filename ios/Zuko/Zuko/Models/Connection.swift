import Foundation

/// A saved host the user can dial back into. The `ticket` is an Iroh endpoint
/// ticket; it encodes a stable node id (because the host persists its secret
/// key) plus last-known addresses, so saved connections keep working across
/// host restarts — Iroh's discovery resolves the current address on dial.
///
/// v0.6 dropped session resume (and with it, the `lastSessionID` field).
/// Each connect gets a fresh PTY on the host; for resumability, run
/// `tmux`/`zellij`/`screen` inside the zuko session. Old keychain entries
/// that still carry `lastSessionID` from a v0.4–v0.5 install load cleanly —
/// Codable ignores unknown keys on decode by default.
struct Connection: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var ticket: String
    var addedAt: Date

    init(id: UUID = UUID(), label: String, ticket: String, addedAt: Date = .now) {
        self.id = id
        self.label = label.isEmpty ? "Host" : label
        self.ticket = ticket
        self.addedAt = addedAt
    }
}

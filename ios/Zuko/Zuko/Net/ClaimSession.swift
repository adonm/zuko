import Foundation
import IrohLib
import Observation
import ZukoFFI

/// Errors from the ticket-handoff claim flow. Surfaced to the UI as the
/// `errorDescription` on each case.
enum ClaimError: LocalizedError {
    /// The Argon2id derivation failed (FFI call returned an error). Should be
    /// rare — the only failure mode is an OS allocation error mid-hash.
    case derivationFailed(String)
    /// Couldn't reach the sharing host within the timeout. Usually means the
    /// code is wrong, `zuko share` already exited, or DNS propagation is slow.
    case dialFailed(String)
    /// The host sent a malformed payload (no ticket, not UTF-8, etc.).
    case handoffFailed(String)

    var errorDescription: String? {
        switch self {
        case .derivationFailed(let m): return "Couldn't derive the pairing key: \(m)"
        case .dialFailed(let m): return m
        case .handoffFailed(let m): return "The host sent an invalid response: \(m)"
        }
    }
}

/// One-shot ticket-handoff client: turns a `zuko share` code into the host's
/// real ticket. Mirrors `src/handoff.rs::claim` (the Rust CLI) step-for-step:
///
/// 1. Derive the throwaway seed from the code via the Rust FFI
///    (`ZukoFFI.deriveHandoffKey` — literally `code::derive_key`, so the
///    derivation is bit-exact with the CLI by construction; no second
///    Argon2id implementation to drift).
/// 2. Construct the `SecretKey` + `EndpointId` (NodeId) from the seed.
/// 3. Bind an endpoint with the derived secret key + the handoff ALPN
///    `zuko/handoff/1`.
/// 4. Dial the derived NodeId via the N0 DNS address-lookup, retrying with
///    backoff (the lookup lags `zuko share` coming online by a few seconds).
/// 5. `acceptUni` + read the `<label>\n<ticket>` payload.
/// 6. **Close the connection** so the host's `serve_handoff` returns and
///    `zuko share` can exit — the same bug we fixed in `handoff.rs` (a
///    missing close made `share` hang for the whole session).
///
/// All async work runs off the main actor; the UI drives it via `Task` and
/// observes the `status` property (Swift 5.9+ `@Observable` macro).
@MainActor
@Observable
final class ClaimSession {
    /// ALPN for the throwaway handoff endpoint (distinct from the terminal `zuko/1`).
    @ObservationIgnored static let alpn = Data("zuko/handoff/1".utf8)
    /// Cap a handoff payload so a misbehaving peer can't make us allocate forever.
    @ObservationIgnored static let maxPayload = 8 * 1024

    private(set) var status: ClaimStatus = .idle

    /// Drive a claim. Returns the claimed `(label, ticket)` on success so the
    /// caller can save it. The session status transitions through
    /// `deriving` → `dialing` → `reading` → `idle` (or `failed` on error).
    func claim(code: String) async throws -> (label: String, ticket: String) {
        status = .deriving

        // 1. Derive the 32-byte seed via the Rust FFI. This is the same
        //    `code::derive_key` the CLI runs, exposed through `src/ffi.rs` —
        //    so the keys agree bit-for-bit and we dial exactly the NodeId
        //    `zuko share` is serving as.
        let seed: Data
        do {
            seed = try ZukoFFI.deriveHandoffKey(code: code)
        } catch {
            let message = Self.derivationMessage(error)
            LogCapture.shared.log(.error, category: "claim", "key derivation failed: \(message)")
            status = .failed(message)
            throw ClaimError.derivationFailed(message)
        }

        // 2. Construct the SecretKey + NodeId we'll dial.
        let secret = try SecretKey.fromBytes(bytes: seed)
        let nodeId = secret.public()

        // 3. Bind a *fresh* endpoint with a random identity. The derived seed
        //    is only used to compute the NodeId we dial — we must NOT bind with
        //    it, or we'd advertise the same NodeId as the host's `share`
        //    endpoint. Two endpoints with the same id on the same relay get
        //    "Another endpoint connected with the same endpoint id" and the
        //    relay silently drops the second one's traffic. (Matches the CLI's
        //    `handoff.rs::claim`, which binds a keyless `presets::N0` endpoint.)
        //    No ALPNs either: claimer is a pure dialer, never an accepter.
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0()
        ))
        await endpoint.online()

        // 4. Dial by NodeId alone, resolved through the N0 DNS address-lookup.
        //    The lookup lags `zuko share` coming online by a few seconds, so
        //    retry with constant backoff (matches the CLI's `dial_throwaway`).
        status = .dialing
        LogCapture.shared.log(.info, category: "claim", "dialing sharing host")
        let addr = EndpointAddr(id: nodeId, relayUrl: nil, addresses: [])
        let conn: IrohLib.Connection
        do {
            conn = try await Self.dialWithRetry(
                endpoint: endpoint, addr: addr, alpn: Self.alpn, timeout: 60
            )
        } catch {
            try? await endpoint.close()
            let msg = "couldn't reach the sharing host — is `zuko share` still running and the code correct?"
            LogCapture.shared.log(.error, category: "claim", "dial failed: \(error.localizedDescription)")
            status = .failed(msg)
            throw ClaimError.dialFailed(msg)
        }

        // 5. Accept the unidirectional stream + read the `<label>\n<ticket>`
        //    payload to end.
        status = .reading
        LogCapture.shared.log(.info, category: "claim", "reading ticket")
        var recv = try await conn.acceptUni()
        let payloadData = try await Self.readToEnd(&recv, max: Self.maxPayload)

        // 6. Close the connection so the host's `serve_handoff` returns and
        //    `zuko share` can exit. Without this (the bug we fixed in
        //    `handoff.rs`), the connection lingers via Iroh's keepalive pings
        //    and `share` hangs for the whole session.
        try? conn.close(errorCode: 0, reason: Data("claimed".utf8))
        try? await endpoint.close()

        guard let payload = String(data: payloadData, encoding: .utf8) else {
            status = .failed("payload wasn't UTF-8")
            throw ClaimError.handoffFailed("payload wasn't UTF-8")
        }
        let (label, ticket) = Self.parsePayload(payload)
        guard !ticket.isEmpty else {
            LogCapture.shared.log(.error, category: "claim", "host sent an empty ticket")
            status = .failed("host sent an empty ticket")
            throw ClaimError.handoffFailed("empty ticket")
        }

        LogCapture.shared.log(.info, category: "claim", "claimed host: \(label)")
        status = .idle
        return (label: label, ticket: ticket)
    }

    /// Extract the human message from a `deriveHandoffKey` failure: the typed
    /// `DeriveKeyError.DerivationFailed` carries one; anything else falls back
    /// to the localized description. Centralised so the original two catch
    /// branches collapse into one.
    private static func derivationMessage(_ error: Error) -> String {
        if case let DeriveKeyError.DerivationFailed(message) = error { return message }
        return error.localizedDescription
    }

    /// Split `<label>\n<ticket>` on the first newline. Labels are newline-free
    /// (sanitised by `zuko share`), and tickets never contain whitespace.
    private static func parsePayload(_ payload: String) -> (label: String, ticket: String) {
        guard let nl = payload.firstIndex(of: "\n") else {
            return ("host", payload.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let label = String(payload[..<nl])
        let ticket = String(payload[payload.index(after: nl)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (label, ticket)
    }

    func reset() {
        status = .idle
    }

    // MARK: - Internals

    /// Dial with constant 2s backoff, up to `timeout` seconds total. The N0
    /// DNS address-lookup can lag `zuko share` coming online by a couple of
    /// seconds; retrying rides out the propagation.
    private static func dialWithRetry(
        endpoint: Endpoint,
        addr: EndpointAddr,
        alpn: Data,
        timeout: TimeInterval
    ) async throws -> IrohLib.Connection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                return try await endpoint.connect(addr: addr, alpn: alpn)
            } catch {
                lastError = error
                try? await Task.sleep(for: .seconds(2))
            }
        }
        throw ClaimError.dialFailed(
            lastError.map { "\($0)" } ?? "timed out after \(Int(timeout))s"
        )
    }

    /// Read a uni recv stream to end, bailing if it exceeds `max` bytes.
    private static func readToEnd(
        _ recv: inout RecvStream,
        max: Int
    ) async throws -> Data {
        var buf = Data()
        while !Task.isCancelled {
            let chunk = try await recv.read(sizeLimit: 4 * 1024)
            if chunk.isEmpty { break }  // end of stream
            buf.append(chunk)
            if buf.count > max {
                throw ClaimError.handoffFailed("payload exceeded \(max) bytes")
            }
        }
        return buf
    }
}

/// Coarse-grained status for the UI to render. Ordered to match the claim
/// flow so a `ProgressView` can show "step N of 3".
enum ClaimStatus: Equatable {
    case idle
    case deriving
    case dialing
    case reading
    case failed(String)

    var step: Int {
        switch self {
        case .idle: return 0
        case .deriving: return 1
        case .dialing: return 2
        case .reading: return 3
        case .failed: return 0
        }
    }

    var label: String {
        switch self {
        case .idle: return ""
        case .deriving: return "Deriving pairing key…"
        case .dialing: return "Reaching the host…"
        case .reading: return "Receiving ticket…"
        case .failed(let m): return m
        }
    }
}

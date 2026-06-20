import Foundation
import IrohLib

enum SessionStatus: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting
    case stalled
    case disconnected(String)
    case failed(String)
}

/// Owns a single Iroh connection to a host and bridges it to SwiftTerm.
///
/// Data flow:
///   - host -> app:  recv loop parses DATA frames -> `onTerminalOutput`
///   - app -> host:  SwiftTerm keystrokes -> `enqueueData` -> serial write pump
///   - resize:       SwiftTerm grid size -> `enqueueResize` -> RESIZE frame
///
/// ## Session resume (v0.4)
///
/// The session runs in a reconnect loop. On a network drop (recv errors) we
/// reconnect and send a `HELLO` carrying the session id the host assigned on
/// the first connection; the host resumes the same PTY, replays recent output,
/// and we keep going. On a genuine shell exit (recv EOF) we stop. A bounded
/// backoff spaces reconnect attempts; `disconnect()` stops the loop.
///
/// ## Heartbeat
///
/// We send a `PING` every ~5 s and answer inbound `PING`s with `PONG`. If no
/// frame arrives for ~10 s we flip to `.stalled` (the UI shows it) — iroh's
/// QUIC keepalive keeps the transport alive, but this surfaces a stuck link to
/// the user faster than the 15–30 s QUIC idle timeout, after which the recv
/// errors and we reconnect.
@MainActor
final class IrohSession: ObservableObject {
    static let alpn = Data("zuko/1".utf8)

    /// Bound on the outbound keystroke/resize queue. With a healthy network
    /// this never fills — frames are tiny and `send.writeAll` drains them
    /// immediately — it's an OOM safety net for a brownout, where the link
    /// times out within ~15–30 s anyway (iroh's path idle timeout). The default
    /// `AsyncStream` buffering policy is `.unbounded`, so without this a user
    /// typing or pasting during an interruption could grow memory without
    /// limit. `.bufferingOldest` preserves the head of any in-flight input
    /// (ordered terminal input is more load-bearing at the front of a sequence
    /// than at the impatient tail) and drops new keystrokes under pressure
    /// rather than blocking the main actor.
    private static let outboundFrameCap = 256

    /// Reconnect backoff: starts here, doubles, caps here.
    private static let backoffMin: Duration = .milliseconds(500)
    private static let backoffMax: Duration = .seconds(5)

    /// Heartbeat: PING interval + stall threshold (no inbound frame for this
    /// long → `.stalled`).
    private static let heartbeatInterval: Duration = .seconds(5)
    private static let stallThresholdSeconds: Double = 10

    @Published private(set) var status: SessionStatus = .idle

    /// Called on the main actor with raw PTY output bytes to render.
    var onTerminalOutput: ((Data) -> Void)?

    /// Fired on the main actor whenever the host assigns/updates our session
    /// id (after a WELCOME). The view persists it on the `Connection` so a
    /// later app launch can resume the same session. `nil` is passed when the
    /// session ends or `disconnect()` clears it.
    var onSessionID: ((Data?) -> Void)?

    private var endpoint: Endpoint?
    private var connection: IrohLib.Connection?

    private var runTask: Task<Void, Never>?
    private var writeContinuation: AsyncStream<Data>.Continuation?

    /// The host-assigned session id for the current/recent session, echoed in
    /// HELLO on reconnect so the host resumes the same PTY. Seeded from the
    /// saved `Connection.lastSessionID` by `connect(ticket:sessionID:)`;
    /// cleared by `disconnect()` (a fresh connect starts a new session).
    private(set) var sessionID: Data?

    /// Tracks whether `disconnect()` was called, so the cancellation handler
    /// can tell an intentional disconnect (we set this, then cancel the task)
    /// apart from an external cancellation.
    private var disconnectRequested = false

    /// Bumped when SwiftTerm reports a new grid size; read by the reconnect
    /// loop so each HELLO carries the current size (and a resumed full-screen
    /// app gets a SIGWINCH → redraw). Packed as cols<<16 | rows.
    private var packedSize: UInt32 = (80 << 16) | 24

    func connect(ticket: String) {
        connect(ticket: ticket, sessionID: nil)
    }

    /// Connect to a host, optionally resuming a prior session by its id.
    /// `sessionID` is the saved `Connection.lastSessionID` (nil for a fresh
    /// session). The host replays the session's recent output on resume.
    func connect(ticket: String, sessionID: Data?) {
        guard !isConnecting else { return }
        disconnectRequested = false
        self.sessionID = sessionID
        status = .connecting
        runTask?.cancel()
        let cleaned = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runReconnectLoop(ticket: cleaned)
        }
    }

    func disconnect() {
        // Record intent *before* cancelling, so the cancellation handler that
        // fires asynchronously sees it and keeps the "disconnected" status we
        // set here (rather than overwriting it with "cancelled").
        disconnectRequested = true
        runTask?.cancel()
        writeContinuation?.finish()
        writeContinuation = nil
        let ep = endpoint
        connection = nil
        endpoint = nil
        sessionID = nil
        onSessionID?(nil)
        status = .disconnected("disconnected")
        // Best-effort graceful close off the hot path.
        Task { try? await ep?.close() }
    }

    private var isConnecting: Bool {
        if case .connecting = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    // MARK: - Outbound (called from SwiftTerm's delegate on the main actor)

    func enqueueData(_ data: Data) {
        writeContinuation?.yield(Wire.encode(type: Wire.data, payload: data))
    }

    func enqueueResize(cols: UInt16, rows: UInt16) {
        packedSize = (UInt32(cols) << 16) | UInt32(rows)
        writeContinuation?.yield(Wire.encodeResize(cols: cols, rows: rows))
    }

    // MARK: - Reconnect loop

    private func runReconnectLoop(ticket: String) async {
        do {
            let ep = try await Endpoint.bind(options: EndpointOptions(preset: presetN0()))
            endpoint = ep
            let addr = try EndpointTicket.fromString(str: ticket).endpointAddr()

            var backoff = Self.backoffMin
            repeat {
                if Task.isCancelled { return }
                do {
                    // Returns normally only on a genuine shell exit (recv
                    // EOF) — in which case we stop reconnecting. Anything else
                    // (dial/stream/handshake failure, mid-session drop) throws
                    // and we back off + reconnect, resuming the session.
                    try await runOneConnection(endpoint: ep, addr: addr)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    // Connection/stream/handshake failure → reconnect (resume).
                    if disconnectRequested { return }
                    // Finish the old write pump so its detached task ends
                    // before the next connection starts a fresh one.
                    writeContinuation?.finish()
                    writeContinuation = nil
                    connection = nil
                    status = .reconnecting
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, Self.backoffMax)
                }
            } while !Task.isCancelled
        } catch is CancellationError {
            if !disconnectRequested { status = .disconnected("cancelled") }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Run one connection attempt: dial, open the bidi stream, do the
    /// HELLO/WELCOME handshake, then drive the read loop + write pump +
    /// heartbeat until the read half ends. Throws on any failure (the caller
    /// backs off and reconnects). Returns normally on a genuine shell exit
    /// (recv EOF → the loop is done and we stop reconnecting).
    private func runOneConnection(endpoint: Endpoint, addr: EndpointAddr) async throws {
        let conn = try await endpoint.connect(addr: addr, alpn: Self.alpn)
        connection = conn
        let bi = try await conn.openBi()
        let send = bi.send()
        let recv = bi.recv()

        // Handshake: HELLO (caps + current size + session id) then a RESIZE.
        // Sent directly on `send` before the write pump touches it, so they're
        // guaranteed first on the wire (a resumed session's ring replay + the
        // PTY's SIGWINCH redraw both depend on the size being known up front).
        let (cols, rows) = unpackSize(packedSize)
        let hello = Wire.encodeHello(
            flags: Wire.flagResume | Wire.flagHeartbeat,
            cols: cols,
            rows: rows,
            sessionID: sessionID
        )
        try await send.writeAll(buf: hello)
        try await send.writeAll(buf: Wire.encodeResize(cols: cols, rows: rows))

        // Start the write pump (detached, owns `send` — see its docs).
        startWritePump(send: send)

        status = .connected

        // Read loop + heartbeat + stall watcher. Returns when recv ends:
        // EOF → shell exited (stop), error → throw (reconnect).
        try await readLoop(recv: recv)

        // Shell exited cleanly — stop the reconnect loop. The write pump is
        // finished + cancelled below; the caller returns normally.
        writeContinuation?.finish()
        status = .disconnected("session ended")
    }

    private func readLoop(recv: RecvStream) async throws {
        var buffer = Data()
        let lastHeard = LastHeard()
        let pongContinuation = writeContinuation

        // Heartbeat: enqueue a PING every interval.
        let pingContinuation = writeContinuation
        let pingTask = Task.detached {
            var nonce: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                if Task.isCancelled { break }
                nonce &+= 1
                pingContinuation?.yield(Wire.encodePing(nonce: nonce))
            }
        }

        // Stall watcher: flip to `.stalled` if no frame has arrived for a while.
        let stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                guard let self else { break }
                if lastHeard.elapsedSeconds() > Self.stallThresholdSeconds {
                    if case .connected = self.status {
                        self.status = .stalled
                    }
                }
            }
        }

        defer {
            pingTask.cancel()
            stallTask.cancel()
        }

        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await recv.read(sizeLimit: 16 * 1024)
            } catch {
                // Network drop → reconnect (resume).
                pingTask.cancel(); stallTask.cancel()
                throw error
            }
            if chunk.isEmpty {
                // Recv EOF → the host closed the stream → shell exited. Stop.
                pingTask.cancel(); stallTask.cancel()
                return
            }
            buffer.append(chunk)
            while let frame = Wire.parse(&buffer) {
                lastHeard.touch()
                switch frame.type {
                case Wire.data:
                    // Recovered from `.stalled` — we're hearing the host again.
                    if case .stalled = status { status = .connected }
                    onTerminalOutput?(Data(frame.payload))
                case Wire.ping:
                    pongContinuation?.yield(Wire.encodePong(nonce: Wire.decodeNonce(frame.payload)))
                case Wire.welcome:
                    // WELCOME is read by the handshake before the loop; if one
                    // arrives here (e.g. a misbehaving host) just adopt its id.
                    if let w = Wire.decodeWelcome(frame.payload) {
                        sessionID = w.sessionID
                        onSessionID?(w.sessionID)
                    }
                default:
                    break // PONG, RESIZE inbound, unknown: ignore
                }
            }
        }
    }

    /// Single long-running consumer that writes frames one at a time. This
    /// guarantees frames never interleave on the wire even when keystrokes and
    /// resize events arrive back-to-back.
    ///
    /// Runs as a `Task.detached` **off the main actor** so output flood on the
    /// read loop can't starve outbound keystrokes. The read loop renders via
    /// `onTerminalOutput` on the main actor (SwiftTerm's ANSI parse + grid
    /// update is synchronous), and a main-actor write pump would only get
    /// scheduled in the gaps between those bursts — under dense output (`vim`
    /// redraw, `yes`, `cat hugefile`) the gaps shrink and keystroke latency
    /// spikes. Detached, the pump ships input on its own thread regardless of
    /// how busy the main actor is with rendering.
    ///
    /// The pump is the sole owner/writer of `send` (Iroh's `SendStream` is
    /// `Arc<Mutex<…>>`, held across each `await`, so this is race-free), and
    /// it signals EOF itself when the loop ends — `disconnect` never touches
    /// `send` directly.
    private func startWritePump(send: SendStream) {
        // `.bufferingOldest` caps the queue; `yield` returns `.dropped` when
        // full, which we intentionally ignore — the link is stalling and will
        // time out shortly, so dropping recent input beats growing memory or
        // blocking SwiftTerm's delegate call on the main actor.
        //
        // `makeStream(of:bufferingPolicy:)` (Swift 6) is used instead of
        // `AsyncStream<Data>(.bufferingOldest(n)) { ... }` because the
        // latter triggers an overload-resolution bug on Xcode 26's Swift 6
        // compiler — the compiler resolves `.bufferingOldest` against
        // `Data.Type` instead of `Continuation.BufferingPolicy`, regardless
        // of explicit type annotations. `makeStream` takes the policy as a
        // labeled argument, which sidesteps the issue.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(Self.outboundFrameCap)
        )
        writeContinuation = continuation
        Task.detached(priority: .userInitiated) {
            // `disconnect` signals shutdown via the continuation (`finish`) +
            // `cancel`; the pump drains what's queued (or aborts on cancel /
            // write error), then signals EOF to the host. No `self` capture:
            // the pump only needs `send` + `stream`, both `Sendable`.
            for await frame in stream {
                if Task.isCancelled { break }
                do {
                    try await send.writeAll(buf: frame)
                } catch {
                    break
                }
            }
            do { try await send.finish() } catch {}
        }
    }

    private func unpackSize(_ packed: UInt32) -> (UInt16, UInt16) {
        (UInt16(packed >> 16), UInt16(packed & 0xFFFF))
    }
}

/// A tiny "last time we heard from the host" tracker for the stall watcher.
/// `touch()` resets; `elapsedSeconds()` reads. The read loop is main-actor-
/// isolated so the accesses are serialised — no lock needed.
private final class LastHeard {
    private var when: Date = .now
    func touch() { when = .now }
    func elapsedSeconds() -> Double { -when.timeIntervalSinceNow }
}

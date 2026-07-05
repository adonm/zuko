import Foundation
import GhosttyTerminal
import IrohLib
import ZukoWire

enum SessionStatus: Equatable {
    case idle
    case connecting
    case reconnecting(attempt: Int, delaySeconds: Int, reason: String)
    case connected
    case disconnected(String)
    case failed(String)
}

/// A permanent, host-deliberate rejection (the host sent an `ERROR` frame).
/// Distinct from a thrown link error so the reconnect loop can fail fast
/// instead of redialing a connection the host has already refused — which
/// would just hammer the host with the same unauthorised token.
private enum PermanentRejection: Error {
    case rejected(String)
}

/// Owns a single Iroh connection to a host and bridges it to GhosttyTerminal's
/// host-managed I/O backend.
///
/// Data flow:
///   - host -> app:  recv loop parses DATA frames -> `inMemorySession.receive`
///   - app -> host:  GhosttyTerminal keystrokes -> writeHandler -> `enqueueData`
///                   -> serial write pump
///   - resize:       GhosttyTerminal grid size -> resizeHandler ->
///                   `enqueueResize` -> RESIZE frame
///
/// The `InMemoryTerminalSession` is created lazily on first access (the view
/// grabs it before calling `connect`). Its `@Sendable` write/resize handlers
/// are fired from libghostty's C surface callbacks on arbitrary threads, so
/// they hop to the main actor before touching any `IrohSession` state.
///
/// ## Reconnect policy
///
/// The iOS client keeps redialing transient Iroh/link failures while the
/// terminal screen is open, with bounded exponential backoff. A stable
/// host-scoped token lets fresh launches land on the same live PTY; once the
/// host replies with ATTACHED, that host-issued token is reused for short drops
/// while the detached lease is alive. Clean EOF (remote shell exited) is not
/// retried. Users running long-lived work should still do so inside `tmux`/
/// `zellij`/`screen` on the host for long disconnects/host restarts.
@MainActor
final class IrohSession: ObservableObject {
    private enum ProtocolVersion: String {
        case v2 = "zuko/2"

        var alpn: Data { Data(rawValue.utf8) }
    }

    /// Bound on the outbound keystroke/resize queue. With a healthy network
    /// this never fills — frames are tiny and `send.writeAll` drains them
    /// immediately — it's an OOM safety net. `.bufferingOldest` preserves the
    /// head of any in-flight input and drops new keystrokes under pressure
    /// rather than blocking the main actor.
    static let outboundFrameCap = 256
    private static let reconnectBaseDelay: UInt64 = 1_000_000_000
    private static let reconnectMaxDelay: UInt64 = 15_000_000_000

    @Published private(set) var status: SessionStatus = .idle

    /// The host-managed I/O bridge between GhosttyTerminal and the Iroh
    /// connection. The terminal surface feeds keystrokes + resizes into this
    /// (via the `@Sendable` write/resize handlers wired up at construction),
    /// and the recv loop calls `receive(_:)` with each inbound DATA frame's
    /// payload so libghostty renders it.
    ///
    /// Lazy so the handlers can capture `[weak self]` — `self` isn't usable
    /// from `init` for that. The view accesses this before `connect(...)` runs
    /// (it sets the surface backend), so the surface is attached by the time
    /// the recv loop starts feeding bytes.
    private(set) lazy var inMemorySession: InMemoryTerminalSession = { [weak self] in
        // The handlers fire on libghostty's C surface callbacks (any thread).
        // Hop to the main actor before touching IrohSession state.
        // `Task { @MainActor … }` is the canonical hop in Swift 6; the cost
        // (one hop per keystroke / per resize) is dwarfed by the AsyncStream
        // + iroh send the pump already does. Data is `Sendable` so capturing
        // it across the hop is safe; the viewport is converted to plain
        // integers before the hop. `self` is captured weakly once, in the
        // lazy initializer's capture list — the inner closures implicitly
        // capture that optional by value (cheap; it holds the weak ref).
        let write: @Sendable (Data) -> Void = { data in
            // Note: the LF→CR translation for software-keyboard Return is
            // handled upstream by the UITerminalView.insertText swizzle
            // (see TerminalInputFix.swift) — by the time bytes reach this
            // callback, Return is already CR. Kept this handler pass-through
            // rather than doubling the translation, so the swizzle is the
            // single source of truth for line-ending normalisation.
            Task { @MainActor in self?.enqueueData(data) }
        }
        let resize: @Sendable (InMemoryTerminalViewport) -> Void = { viewport in
            let cols = UInt16(clamping: Int(viewport.columns))
            let rows = UInt16(clamping: Int(viewport.rows))
            Task { @MainActor in
                self?.enqueueResize(cols: cols, rows: rows)
            }
        }
        return InMemoryTerminalSession(write: write, resize: resize)
    }()

    private var endpoint: Endpoint?
    private var connection: IrohLib.Connection?

    private var runTask: Task<Void, Never>?
    var controlReadTask: Task<Void, Never>?
    var writeContinuation: AsyncStream<Data>.Continuation?

    /// Tracks whether `disconnect()` was called, so the task's cancellation
    /// handler can tell an intentional disconnect (we set this, then cancel)
    /// apart from an external cancellation.
    private var disconnectRequested = false

    /// The ticket from the most recent `connect(ticket:)`, kept so
    /// `foregrounded()` can redial after the app was suspended without the
    /// view having to re-supply it.
    private var lastTicket: String?

    /// Bumped when GhosttyTerminal reports a new grid size; read by the
    /// connect path so the initial RESIZE carries the current size. Packed as
    /// cols<<16 | rows.
    private var packedSize: UInt32 = (80 << 16) | 24

    /// 16-byte session token. Starts as a stable token derived from this app
    /// install + host id (or zero if Keychain is unavailable), then is updated
    /// from ATTACHED. Zero means "start a fresh PTY"; non-zero asks the host to
    /// create-or-reattach that token's PTY. The host may reply with a different
    /// token if the lease expired, which we accept.
    private var sessionToken = Data(repeating: 0, count: Wire.sessionTokenLength)

    /// Connect to a host and keep reconnecting transient link failures until
    /// `disconnect()` or view teardown cancels the run task. Reconnects reuse
    /// the host's session token and reattach if the detached lease is alive.
    func connect(ticket: String) {
        guard !isRunning else { return }
        disconnectRequested = false
        status = .connecting
        runTask?.cancel()
        let cleaned = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTicket = cleaned
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runConnectionLoop(ticket: cleaned)
        }
    }

    func disconnect() {
        // Record intent *before* cancelling, so the connection task sees it
        // and reports `.disconnected("disconnected")` rather than treating
        // the cancellation as a failure.
        disconnectRequested = true
        LogCapture.shared.log(.info, category: "net", "disconnect requested")
        runTask?.cancel()
        controlReadTask?.cancel()
        controlReadTask = nil
        writeContinuation?.finish()
        writeContinuation = nil
        let ep = endpoint
        connection = nil
        endpoint = nil
        status = .disconnected("disconnected")
        // Best-effort graceful close off the hot path.
        Task { try? await ep?.close() }
    }

    private var isRunning: Bool {
        if case .connected = status { return true }
        if case .connecting = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    // MARK: - Outbound (called from GhosttyTerminal's surface callbacks via
    //                    the InMemoryTerminalSession handlers; hopped to the
    //                    main actor before reaching here)

    func enqueueData(_ data: Data) {
        writeContinuation?.yield(Wire.encode(type: Wire.data, payload: data))
    }

    func enqueueResize(cols: UInt16, rows: UInt16) {
        packedSize = (UInt32(cols) << 16) | UInt32(rows)
        writeContinuation?.yield(Wire.encodeResize(cols: cols, rows: rows))
    }

    func requestRedraw() {
        let (cols, rows) = unpackSize(packedSize)
        enqueueResize(cols: cols, rows: rows)
    }

    /// Recover when the app returns to the foreground. iOS freezes our tasks
    /// while suspended and the OS usually tears down the QUIC link, so a
    /// session that still *looks* connected is often talking to a dead path.
    ///
    /// - `.connected`: nudge a repaint. The RESIZE rides the write pump; if the
    ///   link is dead the pump's `writeAll` fails and the (now-resumed) read
    ///   loop errors, so the run loop redials. If the link is fine, the host
    ///   just re-emits the current screen — cheap and idempotent.
    /// - `.idle`/`.disconnected`/`.failed`: redial now via `connect` (a no-op
    ///   guard while already `.connecting`/`.reconnecting`, where the existing
    ///   backoff loop is already retrying).
    ///
    /// Only calls already-safe, guarded entry points so there's no new
    /// concurrency to reason about on the lifecycle path.
    func foregrounded() {
        LogCapture.shared.log(.info, category: "net", "app foregrounded")
        if case .connected = status {
            requestRedraw()
            return
        }
        // A permanent rejection (host sent ERROR, e.g. not authorised) must
        // not be retried on every foreground — the host has refused this
        // client and redialing just hammers it. The user re-pairs to recover.
        if case .failed = status {
            return
        }
        if let ticket = lastTicket {
            connect(ticket: ticket)
        }
    }

    // MARK: - Connection

    /// Parse the ticket once, bind one local Iroh endpoint for this terminal
    /// screen, derive this install's stable host-scoped reattach token, then
    /// redial transient failures with bounded exponential backoff.
    /// Reusing the endpoint keeps relay/NAT state warm across attempts and
    /// avoids churning local identities; each successful stream still creates a
    /// fresh host PTY.
    private func runConnectionLoop(ticket: String) async {
        let endpointTicket: EndpointTicket
        let ep: Endpoint
        do {
            endpointTicket = try EndpointTicket.fromString(str: ticket)
            sessionToken = try ClientIdentity.sessionToken(for: endpointTicket)
            ep = try await Endpoint.bind(options: EndpointOptions(preset: presetN0()))
            endpoint = ep
        } catch {
            LogCapture.shared.log(.error, category: "net", "endpoint bind failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
            return
        }
        defer { closeEndpoint(ep) }

        var attempt = 0
        while !Task.isCancelled, !disconnectRequested {
            do {
                if attempt == 0 {
                    status = .connecting
                }
                try await runOneConnection(
                    endpoint: ep,
                    endpointTicket: endpointTicket
                )
                status = .disconnected("session ended")
                return
            } catch is CancellationError {
                reportCancellationIfNeeded()
                return
            } catch let PermanentRejection.rejected(_) {
                // Status was already set to `.failed` in `readLoop` with the
                // host's message + re-pair hint. Do NOT retry: the host has
                // refused this client and redialing would hammer it forever.
                return
            } catch {
                LogCapture.shared.log(
                    .warn,
                    category: "net",
                    "connection \(attempt == 0 ? "failed" : "dropped"): \(error.localizedDescription)"
                )
                attempt += 1
                if await waitBeforeReconnect(after: error, attempt: attempt) == false {
                    return
                }
            }
        }

        reportCancellationIfNeeded()
    }

    private func waitBeforeReconnect(after error: Error, attempt: Int) async -> Bool {
        connection = nil
        if disconnectRequested {
            status = .disconnected("disconnected")
            return false
        }

        let delay = reconnectDelay(forAttempt: attempt)
        let seconds = max(1, Int(delay / 1_000_000_000))
        status = .reconnecting(
            attempt: attempt,
            delaySeconds: seconds,
            reason: error.localizedDescription
        )
        LogCapture.shared.log(.warn, category: "net", "reconnect attempt \(attempt) in \(seconds)s")

        do {
            try await Task.sleep(nanoseconds: delay)
            return true
        } catch {
            reportCancellationIfNeeded()
            return false
        }
    }

    private func reportCancellationIfNeeded() {
        if !disconnectRequested {
            status = .disconnected("cancelled")
        }
    }

    /// Dial, send the initial ATTACH (including terminal size), and pump bytes
    /// both ways until EOF (clean shell exit) or a thrown link error.
    private func runOneConnection(
        endpoint: Endpoint,
        endpointTicket: EndpointTicket
    ) async throws {
        do {
            let addr = endpointTicket.endpointAddr()
            // Stall boundary: the gap between this "dialing" line and the
            // "connected" one below shows where iroh is stuck (relay/NAT).
            LogCapture.shared.log(.info, category: "net", "dialing host")
            let conn = try await connectPreferred(endpoint: endpoint, addr: addr)
            connection = conn
            LogCapture.shared.log(
                .info,
                category: "net",
                "connected via \(ProtocolVersion.v2.rawValue) — opening stream"
            )
            let bi = try await Self.withConnectionTimeout(phase: "open stream") {
                try await conn.openBi()
            }
            let send = bi.send()
            let recv = bi.recv()
            let (controlSend, controlRecv) = await openControlStreamIfAvailable(
                conn: conn
            )
            LogCapture.shared.log(.info, category: "net", "stream open — sending attach")

            // Initial ATTACH — tells the host the grid size and the last
            // session token we saw. Zero token starts a fresh PTY; non-zero
            // reattaches a still-leased PTY after a short mobile link drop.
            // Sent directly before the write pump touches the stream, so it's
            // guaranteed first on the wire.
            let (cols, rows) = unpackSize(packedSize)
            let attach = Wire.encodeAttach(token: sessionToken, cols: cols, rows: rows)
            try await Self.withConnectionTimeout(phase: "send attach") {
                try await send.writeAll(buf: attach)
            }
            LogCapture.shared.log(.info, category: "net", "attach sent")

            if let controlRecv {
                startControlReadPump(recv: controlRecv)
            }

            // Start the write pump (detached, owns `send` and, for v2, the
            // optional `controlSend` — see its docs).
            startWritePump(send: send, controlSend: controlSend)

            status = .connected

            // Read loop — runs until EOF (host closed → shell exited) or
            // error (network drop). Iroh/QUIC owns transport liveness; the
            // outer loop redials stream errors.
            try await readLoop(recv: recv)

            writeContinuation?.finish()
            writeContinuation = nil
            controlReadTask?.cancel()
            controlReadTask = nil
            connection = nil
        } catch {
            writeContinuation?.finish()
            writeContinuation = nil
            controlReadTask?.cancel()
            controlReadTask = nil
            connection = nil
            throw error
        }
    }

    private func connectPreferred(
        endpoint: Endpoint,
        addr: EndpointAddr
    ) async throws -> IrohLib.Connection {
        try await Self.withConnectionTimeout(phase: "dial host zuko/2") {
            try await endpoint.connect(addr: addr, alpn: ProtocolVersion.v2.alpn)
        }
    }

    private func openControlStreamIfAvailable(
        conn: IrohLib.Connection
    ) async -> (SendStream?, RecvStream?) {
        do {
            let controlBi = try await Self.withConnectionTimeout(phase: "open control stream") {
                try await conn.openBi()
            }
            LogCapture.shared.log(.info, category: "net", "control stream open")
            return (controlBi.send(), controlBi.recv())
        } catch {
            LogCapture.shared.log(
                .warn,
                category: "net",
                "control stream unavailable; using data stream for control: \(error.localizedDescription)"
            )
            return (nil, nil)
        }
    }

    private func closeEndpoint(_ ep: Endpoint) {
        endpoint = nil
        Task { try? await ep.close() }
    }

    private func reconnectDelay(forAttempt attempt: Int) -> UInt64 {
        let shift = UInt64(min(max(attempt - 1, 0), 4))
        let delay = Self.reconnectBaseDelay << shift
        return min(delay, Self.reconnectMaxDelay)
    }

    /// Consume the primary stream until EOF (host closed → shell exited) or a
    /// link error. The blocking read + framing runs off the main actor (see
    /// `Self.frameStream`); only `handleInboundFrame` — which touches the
    /// libghostty surface and session state — runs here on the main actor.
    /// Returning/throwing drives the reconnect loop exactly as before, except
    /// a host-sent `ERROR` frame throws `PermanentRejection` so the outer loop
    /// stops retrying instead of treating a deliberate refusal like a blip.
    private func readLoop(recv: RecvStream) async throws {
        for try await frame in Self.frameStream(recv: recv) {
            if frame.type == Wire.error {
                // The host rejected this connection deliberately (e.g. this
                // client isn't authorised). Surfacing as `.failed` and
                // throwing `PermanentRejection` stops the reconnect loop;
                // redialing would just hit the same rejection every second.
                let parsed = Wire.parseError(frame.payload)
                let code = parsed?.code
                let message = parsed?.message ?? "host rejected the connection"
                let hint = code == Wire.ErrorCode.authorization
                    ? " — re-pair this host with `zuko share` on the host"
                    : ""
                LogCapture.shared.log(.warn, category: "net", "host rejected: \(message)\(hint)")
                status = .failed("\(message)\(hint)")
                throw PermanentRejection.rejected(message)
            }
            handleInboundFrame(frame)
        }
    }

    func handleInboundFrame(_ frame: Wire.Frame) {
        switch frame.type {
        case Wire.data:
            // Hand the raw PTY bytes to libghostty for ANSI parse + grid
            // update. `receive(_:)` is lock-protected on the
            // InMemoryTerminalSession.
            inMemorySession.receive(Data(frame.payload))
        case Wire.ping:
            // App-level heartbeats are optional; reply on the serial write pump
            // so the response stays framed with all other outbound data.
            enqueuePong(frame.payload)
        case Wire.attached:
            if let token = Wire.parseAttached(frame.payload) {
                sessionToken = token
                LogCapture.shared.log(.info, category: "net", "host attached")
            }
        default:
            break // PONG / unknown: ignore
        }
    }

    private func enqueuePong(_ payload: [UInt8]) {
        writeContinuation?.yield(Wire.encode(type: Wire.pong, payload: Data(payload)))
    }

    private func unpackSize(_ packed: UInt32) -> (UInt16, UInt16) {
        (UInt16(packed >> 16), UInt16(packed & 0xFFFF))
    }
}

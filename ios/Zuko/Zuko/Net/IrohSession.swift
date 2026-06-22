import Foundation
import GhosttyTerminal
import IrohLib

enum SessionStatus: Equatable {
    case idle
    case connecting
    case reconnecting(attempt: Int, delaySeconds: Int, reason: String)
    case connected
    case disconnected(String)
    case failed(String)
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
/// terminal screen is open, with bounded exponential backoff. It sends the
/// host-issued session token on each reconnect, so short drops reattach the
/// same PTY while the host lease is alive. Clean EOF (remote shell exited) is
/// not retried. Users running long-lived work should still do so inside
/// `tmux`/`zellij`/`screen` on the host for long disconnects/host restarts.
@MainActor
final class IrohSession: ObservableObject {
    static let alpn = Data("zuko/1".utf8)

    /// Bound on the outbound keystroke/resize queue. With a healthy network
    /// this never fills — frames are tiny and `send.writeAll` drains them
    /// immediately — it's an OOM safety net. `.bufferingOldest` preserves the
    /// head of any in-flight input and drops new keystrokes under pressure
    /// rather than blocking the main actor.
    private static let outboundFrameCap = 256
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
    private var writeContinuation: AsyncStream<Data>.Continuation?

    /// Tracks whether `disconnect()` was called, so the task's cancellation
    /// handler can tell an intentional disconnect (we set this, then cancel)
    /// apart from an external cancellation.
    private var disconnectRequested = false

    /// Bumped when GhosttyTerminal reports a new grid size; read by the
    /// connect path so the initial RESIZE carries the current size. Packed as
    /// cols<<16 | rows.
    private var packedSize: UInt32 = (80 << 16) | 24

    /// Host-issued 16-byte session token. Zero means "start a fresh PTY";
    /// non-zero asks the host to reattach the still-leased PTY after a short
    /// mobile link drop. The host may reply with a different token if the lease
    /// expired, which we accept.
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
        runTask?.cancel()
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

    // MARK: - Connection

    /// Parse the ticket once, bind one local Iroh endpoint for this terminal
    /// screen, then redial transient failures with bounded exponential backoff.
    /// Reusing the endpoint keeps relay/NAT state warm across attempts and
    /// avoids churning local identities; each successful stream still creates a
    /// fresh host PTY.
    private func runConnectionLoop(ticket: String) async {
        let endpointTicket: EndpointTicket
        let ep: Endpoint
        do {
            endpointTicket = try EndpointTicket.fromString(str: ticket)
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
            } catch {
                LogCapture.shared.log(.warn, category: "net", "connection \(attempt == 0 ? "failed" : "dropped"): \(error.localizedDescription)")
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

    /// Dial, send the initial RESIZE (v0.6 handshake — also tells the host
    /// the terminal size before the first byte of input flows), and pump bytes
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
            let conn = try await endpoint.connect(addr: addr, alpn: Self.alpn)
            connection = conn
            LogCapture.shared.log(.info, category: "net", "connected — opening stream")
            let bi = try await conn.openBi()
            let send = bi.send()
            let recv = bi.recv()

            // Initial ATTACH — tells the host the grid size and the last
            // session token we saw. Zero token starts a fresh PTY; non-zero
            // reattaches a still-leased PTY after a short mobile link drop.
            // Sent directly before the write pump touches the stream, so it's
            // guaranteed first on the wire.
            let (cols, rows) = unpackSize(packedSize)
            try await send.writeAll(
                buf: Wire.encodeAttach(token: sessionToken, cols: cols, rows: rows)
            )

            // Start the write pump (detached, owns `send` — see its docs).
            startWritePump(send: send)

            status = .connected

            // Read loop — runs until EOF (host closed → shell exited) or
            // error (network drop). Iroh/QUIC owns transport liveness; the
            // outer loop redials stream errors.
            try await readLoop(recv: recv)

            writeContinuation?.finish()
            writeContinuation = nil
            connection = nil
        } catch {
            writeContinuation?.finish()
            writeContinuation = nil
            connection = nil
            throw error
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

    private func readLoop(recv: RecvStream) async throws {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await recv.read(sizeLimit: 16 * 1024)
            } catch {
                throw error
            }
            if chunk.isEmpty {
                // Recv EOF → the host closed the stream → shell exited.
                return
            }
            buffer.append(chunk)
            while let frame = Wire.parse(&buffer) {
                switch frame.type {
                case Wire.data:
                    // Hand the raw PTY bytes to libghostty for ANSI parse +
                    // grid update. `receive(_:)` is lock-protected on the
                    // InMemoryTerminalSession.
                    inMemorySession.receive(Data(frame.payload))
                case Wire.ping:
                    // v0.6 hosts don't initiate app-level heartbeats today,
                    // but PING/PONG remains in the protocol for compatibility.
                    // Reply on the serial write pump so the response stays
                    // framed with all other outbound data.
                    enqueuePong(frame.payload)
                case Wire.attached:
                    if let token = Wire.parseAttached(frame.payload) {
                        sessionToken = token
                    }
                default:
                    break // PONG, legacy HELLO/WELCOME, unknown: ignore
                }
            }
        }
    }

    private func enqueuePong(_ payload: [UInt8]) {
        writeContinuation?.yield(Wire.encode(type: Wire.pong, payload: Data(payload)))
    }

    /// Single long-running consumer that writes frames one at a time. This
    /// guarantees frames never interleave on the wire even when keystrokes and
    /// resize events arrive back-to-back.
    ///
    /// Runs as a `Task.detached` **off the main actor** so output flood on the
    /// read loop can't starve outbound keystrokes. The read loop renders via
    /// `inMemorySession.receive` on the main actor (libghostty's ANSI parse +
    /// grid update is synchronous), and a main-actor write pump would only get
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
        // blocking GhosttyTerminal's surface callback.
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

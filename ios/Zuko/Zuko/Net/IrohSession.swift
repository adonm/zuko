import Foundation
import GhosttyTerminal
import IrohLib

enum SessionStatus: Equatable {
    case idle
    case connecting
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
/// ## Single-shot (v0.6)
///
/// No auto-reconnect, no heartbeat, no session resume. The connection lives
/// for as long as the iroh stream is open; on drop (network loss, host down,
/// shell exit) `status` flips to `.disconnected(reason)` and the user is
/// prompted to reconnect by navigating back and tapping the connection again
/// (or re-invoking `connect`). Users running long-lived work should do so
/// inside `tmux`/`zellij`/`screen` on the host — that's the proper layer for
/// resumability.
@MainActor
final class IrohSession: ObservableObject {
    static let alpn = Data("zuko/1".utf8)

    /// Bound on the outbound keystroke/resize queue. With a healthy network
    /// this never fills — frames are tiny and `send.writeAll` drains them
    /// immediately — it's an OOM safety net. `.bufferingOldest` preserves the
    /// head of any in-flight input and drops new keystrokes under pressure
    /// rather than blocking the main actor.
    private static let outboundFrameCap = 256

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

    /// Connect to a host. Single-shot in v0.6 — no resume, no reconnect loop.
    /// On connection end the status flips to `.disconnected` or `.failed` and
    /// the caller (or the user) decides whether to try again.
    func connect(ticket: String) {
        guard !isConnecting else { return }
        disconnectRequested = false
        status = .connecting
        runTask?.cancel()
        let cleaned = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runOneConnection(ticket: cleaned)
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

    private var isConnecting: Bool {
        if case .connecting = status { return true }
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

    // MARK: - Connection

    /// Dial, send the initial RESIZE (v0.6 handshake — also tells the host
    /// the terminal size before the first byte of input flows), pump bytes
    /// both ways until the stream ends, then surface the outcome as
    /// `.disconnected` or `.failed`.
    private func runOneConnection(ticket: String) async {
        do {
            let ep = try await Endpoint.bind(options: EndpointOptions(preset: presetN0()))
            endpoint = ep
            let addr = try EndpointTicket.fromString(str: ticket).endpointAddr()

            let conn = try await ep.connect(addr: addr, alpn: Self.alpn)
            connection = conn
            let bi = try await conn.openBi()
            let send = bi.send()
            let recv = bi.recv()

            // Initial RESIZE — acts as the v0.6 handshake (tells the host the
            // grid size before any input flows). Sent directly on `send`
            // before the write pump touches it, so it's guaranteed first on
            // the wire.
            let (cols, rows) = unpackSize(packedSize)
            try await send.writeAll(buf: Wire.encodeResize(cols: cols, rows: rows))

            // Start the write pump (detached, owns `send` — see its docs).
            startWritePump(send: send)

            status = .connected

            // Read loop — runs until EOF (host closed → shell exited) or
            // error (network drop). No heartbeat/stall watcher in v0.6.
            try await readLoop(recv: recv)

            writeContinuation?.finish()
            writeContinuation = nil
            connection = nil
            status = .disconnected("session ended")
        } catch is CancellationError {
            if !disconnectRequested {
                status = .disconnected("cancelled")
            }
        } catch {
            connection = nil
            if disconnectRequested {
                status = .disconnected("disconnected")
            } else {
                status = .failed(error.localizedDescription)
            }
        }
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
                default:
                    break // PING, PONG, legacy HELLO/WELCOME, unknown: ignore
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

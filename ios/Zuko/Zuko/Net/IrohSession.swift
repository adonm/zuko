import Foundation
import IrohLib

enum SessionStatus: Equatable {
    case idle
    case connecting
    case connected
    case disconnected(String)
    case failed(String)
}

/// Owns a single Iroh connection to a host and bridges it to SwiftTerm.
///
/// Data flow:
///   - host -> app:  recv loop parses DATA frames -> `onTerminalOutput`
///   - app -> host:  SwiftTerm keystrokes -> `enqueueData` -> serial write pump
///   - resize:       SwiftTerm grid size -> `enqueueResize` -> RESIZE frame
@MainActor
final class IrohSession: ObservableObject {
    static let alpn = Data("zuko/1".utf8)

    @Published private(set) var status: SessionStatus = .idle

    /// Called on the main actor with raw PTY output bytes to render.
    var onTerminalOutput: ((Data) -> Void)?

    private var endpoint: Endpoint?
    private var connection: IrohLib.Connection?
    private var sendStream: SendStream?
    private var recvStream: RecvStream?

    private var connectTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var writeContinuation: AsyncStream<Data>.Continuation?

    /// Tracks whether `disconnect()` was called for this session, so the
    /// `CancellationError` handler can tell an intentional disconnect (we set
    /// this, then cancel the task) apart from an external cancellation (the
    /// task was cancelled some other way). Replaces a fragile string-equality
    /// check on `status == .disconnected("disconnected")` that silently broke
    /// whenever the associated-value literal changed.
    private var disconnectRequested = false

    func connect(ticket: String) {
        guard status != .connecting, status != .connected else { return }
        // A new connection attempt means any prior disconnect intent is no
        // longer current — reset so the cancellation handler below reports
        // "cancelled" rather than "disconnected" if this attempt is torn down
        // before completion.
        disconnectRequested = false
        status = .connecting
        connectTask?.cancel()
        let cleaned = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        connectTask = Task { [weak self] in
            guard let self else { return }
            await self.runConnect(ticket: cleaned)
        }
    }

    func disconnect() {
        // Record intent *before* cancelling, so the cancellation handler that
        // fires asynchronously sees it and keeps the "disconnected" status we
        // set here (rather than overwriting it with "cancelled").
        disconnectRequested = true
        connectTask?.cancel()
        writeContinuation?.finish()
        writeTask?.cancel()
        let ep = endpoint
        let send = sendStream
        sendStream = nil
        recvStream = nil
        connection = nil
        endpoint = nil
        status = .disconnected("disconnected")
        // Best-effort graceful close off the hot path.
        Task { try? await send?.finish(); try? await ep?.close() }
    }

    // MARK: - Outbound (called from SwiftTerm's delegate on the main actor)

    func enqueueData(_ data: Data) {
        writeContinuation?.yield(Wire.encode(type: Wire.data, payload: data))
    }

    func enqueueResize(cols: UInt16, rows: UInt16) {
        writeContinuation?.yield(Wire.encodeResize(cols: cols, rows: rows))
    }

    // MARK: - Internals

    private func runConnect(ticket: String) async {
        do {
            let ep = try await Endpoint.bind(options: EndpointOptions(preset: presetN0()))
            endpoint = ep

            let addr = try EndpointTicket.fromString(str: ticket).endpointAddr()
            let conn = try await ep.connect(addr: addr, alpn: Self.alpn)
            connection = conn

            // The opener must write before the peer's accept_bi resolves, so we
            // send an initial resize right away (the real size follows on the
            // first SwiftTerm layout pass).
            let bi = try await conn.openBi()
            sendStream = bi.send()
            recvStream = bi.recv()
            startWritePump()
            enqueueResize(cols: 80, rows: 24)
            status = .connected

            await readLoop()
        } catch is CancellationError {
            // `disconnect()` flips `disconnectRequested` before cancelling, so
            // we keep its "disconnected" status. Any other cancellation
            // (parent Task cancelled, view dismissed, etc.) is reported as
            // "cancelled".
            if !disconnectRequested {
                status = .disconnected("cancelled")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func readLoop() async {
        guard let recv = recvStream else { return }
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await recv.read(sizeLimit: 16 * 1024)
            } catch {
                break
            }
            // Iroh returns an empty read at end-of-stream.
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let frame = Wire.parse(&buffer) {
                if frame.type == Wire.data {
                    onTerminalOutput?(Data(frame.payload))
                }
                // Inbound RESIZE frames are host->client, which we don't expect.
            }
        }
        if !Task.isCancelled {
            status = .disconnected("connection closed")
        }
    }

    /// Single long-running consumer that writes frames one at a time. This
    /// guarantees frames never interleave on the wire even when keystrokes and
    /// resize events arrive back-to-back.
    private func startWritePump() {
        guard let send = sendStream else { return }
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { c in continuation = c }
        writeContinuation = continuation
        writeTask = Task { [weak self] in
            for await frame in stream {
                guard self != nil else { break }
                do {
                    try await send.writeAll(buf: frame)
                } catch {
                    break
                }
            }
        }
    }
}

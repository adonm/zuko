import Foundation
import IrohLib
import ZukoWire

/// Error thrown when a connection-setup phase (dial, open stream, send attach)
/// outruns `connectionPhaseTimeoutNanoseconds` — surfaced so a wedged
/// relay/NAT path fails fast and the reconnect loop can redial.
private struct ConnectionPhaseTimeout: LocalizedError, Sendable {
    let phase: String
    let seconds: Int

    var errorDescription: String? {
        "\(phase) timed out after \(seconds)s"
    }
}

private let connectionPhaseTimeoutNanoseconds: UInt64 = 20_000_000_000

extension IrohSession {
    /// Race `operation` against a fixed timeout so a stuck dial/stream/attach
    /// can't hang the connection loop forever. Whichever finishes first wins;
    /// the loser is cancelled. Lives here (with the other transport plumbing)
    /// to keep `IrohSession.swift` focused on lifecycle/state.
    static func withConnectionTimeout<T: Sendable>(
        phase: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .userInitiated) {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: connectionPhaseTimeoutNanoseconds)
                throw ConnectionPhaseTimeout(
                    phase: phase,
                    seconds: Int(connectionPhaseTimeoutNanoseconds / 1_000_000_000)
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}

extension IrohSession {
    /// Single long-running consumer that writes frames one at a time, off the
    /// main actor, so output rendering cannot starve keystroke delivery. In
    /// protocol v2, RESIZE/PING/PONG use the optional control stream; DATA stays
    /// on the primary stream. If the control stream disappears during teardown,
    /// control frames fall back to the primary stream until reconnect takes over.
    /// A primary-stream write failure closes the connection so a dead path does
    /// not sit in `.connected` until the read side notices naturally.
    func startWritePump(
        send: SendStream,
        controlSend: SendStream?,
        connection: IrohLib.Connection
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(Self.outboundFrameCap)
        )
        writeContinuation = continuation

        Task.detached(priority: .userInitiated) {
            var activeControlSend = controlSend
            var writeFailure: String?
            for await frame in stream {
                if Task.isCancelled { break }
                do {
                    if Wire.isControlFrame(frame), let control = activeControlSend {
                        do {
                            try await control.writeAll(buf: frame)
                            continue
                        } catch {
                            activeControlSend = nil
                        }
                    }
                    try await send.writeAll(buf: frame)
                } catch {
                    writeFailure = error.localizedDescription
                    break
                }
            }
            if let activeControlSend {
                do { try await activeControlSend.finish() } catch {}
            }
            do { try await send.finish() } catch {}
            if let writeFailure {
                try? connection.close(errorCode: 1, reason: Data(writeFailure.utf8))
            }
        }
    }

    func startControlReadPump(recv: RecvStream) {
        controlReadTask?.cancel()
        controlReadTask = Task { [weak self] in
            guard let self else { return }
            // Off-main read + framing; dispatch on the main actor (this Task
            // inherits IrohSession's @MainActor isolation).
            do {
                for try await frame in Self.frameStream(recv: recv) {
                    handleInboundFrame(frame)
                }
            } catch {
                // Control stream ended/errored; the data stream + reconnect
                // loop own liveness, so just stop pumping control frames.
            }
        }
    }

    /// Read `recv` and decode the length-prefixed framing **off the main
    /// actor**, yielding `Wire.Frame` values (Sendable) to a main-actor
    /// consumer. The producer runs detached so network reads, buffering, and
    /// framing never occupy the main actor — only the per-frame dispatch
    /// (libghostty `receive`, which is UI-bound) does. Finishes on EOF (empty
    /// read) and throws on a link error so the caller's reconnect logic fires.
    static func frameStream(recv: RecvStream) -> AsyncThrowingStream<Wire.Frame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var decoder = FrameDecoder()
                do {
                    while !Task.isCancelled {
                        let chunk = try await recv.read(sizeLimit: 16 * 1024)
                        if chunk.isEmpty { break }  // EOF
                        decoder.append(chunk)
                        while let frame = decoder.next() {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

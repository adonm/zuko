package dev.adonm.zuko.net

import computer.iroh.BiStream
import computer.iroh.Connection
import computer.iroh.Endpoint
import computer.iroh.EndpointOptions
import computer.iroh.EndpointTicket
import computer.iroh.RecvStream
import computer.iroh.SendStream
import computer.iroh.presetN0
import dev.adonm.zuko.core.ClientIdentity
import dev.adonm.zuko.core.ReconnectBackoff
import dev.adonm.zuko.core.SavedHost
import dev.adonm.zuko.core.Wire
import dev.adonm.zuko.terminal.GhosttyTerminal
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.coroutineContext

sealed interface SessionStatus {
    data object Idle : SessionStatus
    data object Connecting : SessionStatus
    data class Reconnecting(val attempt: Int, val delaySeconds: Int, val reason: String) : SessionStatus
    data object Connected : SessionStatus
    data class Ended(val reason: String) : SessionStatus
    data class Failed(val reason: String, val canRePair: Boolean) : SessionStatus
}

class IrohSession(
    private val scope: CoroutineScope,
    private val terminal: GhosttyTerminal,
    private val onStatus: (SessionStatus) -> Unit,
    private val onAttached: () -> Unit,
) : AutoCloseable {
    // A fresh queue is published only while an attachment is live. Keeping the
    // queue connection-scoped prevents input typed offline from reaching a new
    // shell after reconnect.
    private val outbound = AtomicReference<Channel<ByteArray>?>(null)
    private val closed = AtomicBoolean(false)
    private val backoff = ReconnectBackoff()
    private var job: Job? = null
    private var connection: Connection? = null
    private var endpoint: Endpoint? = null

    fun start(host: SavedHost, clientSeed: ByteArray) {
        check(job == null) { "session already started" }
        job = scope.launch(Dispatchers.IO) { runLoop(host, clientSeed) }
    }

    fun sendInput(data: ByteArray) {
        if (data.isEmpty() || closed.get()) return
        val active = outbound.get() ?: return
        Wire.encodeData(data).forEach(active::trySend)
    }

    fun sendKey(androidKeyCode: Int, modifiers: Int = 0, text: ByteArray? = null) {
        val encoded = terminal.encodeKey(androidKeyCode, modifiers, text)
        sendInput(encoded)
    }

    fun resize(geometry: GhosttyTerminal.Geometry) {
        outbound.get()?.trySend(
            Wire.encodeResize(
                Wire.Size(geometry.cols, geometry.rows, geometry.pixelWidth, geometry.pixelHeight),
            ),
        )
    }

    fun requestRedraw() = resize(terminal.geometry.value)

    private suspend fun runLoop(host: SavedHost, clientSeed: ByteArray) {
        val ticket = try {
            EndpointTicket.fromString(host.ticket)
        } catch (error: Throwable) {
            onStatus(SessionStatus.Failed("Saved connection information is invalid.", canRePair = false))
            return
        }
        val token = ClientIdentity.sessionToken(clientSeed, host.nodeId)
        val ticketNodeId = ticket.endpointAddr().use { address -> address.id().use { it.toString() } }
        if (ticketNodeId != host.nodeId) {
            ticket.close()
            onStatus(SessionStatus.Failed("Saved host identity does not match its ticket.", canRePair = false))
            return
        }
        val localEndpoint = try {
            Endpoint.bind(EndpointOptions(preset = presetN0()))
        } catch (error: Throwable) {
            ticket.close()
            onStatus(SessionStatus.Failed(error.safeMessage(), canRePair = false))
            return
        }
        endpoint = localEndpoint
        try {
            while (!closed.get()) {
                coroutineContext.ensureActive()
                if (backoff.attempt == 0) onStatus(SessionStatus.Connecting)
                try {
                    runOne(localEndpoint, ticket, token)
                    onStatus(SessionStatus.Ended("Session ended"))
                    return
                } catch (rejected: PermanentRejection) {
                    onStatus(SessionStatus.Failed(rejected.message.orEmpty(), rejected.authorization))
                    return
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    if (closed.get()) return
                    val step = backoff.recordFailure()
                    onStatus(SessionStatus.Reconnecting(step.attempt, step.delaySeconds, error.safeMessage()))
                    delay(step.delaySeconds * 1_000L)
                }
            }
        } finally {
            endpoint = null
            runCatching { localEndpoint.shutdown() }
            localEndpoint.close()
            ticket.close()
            if (closed.get()) onStatus(SessionStatus.Ended("Disconnected"))
        }
    }

    private suspend fun runOne(endpoint: Endpoint, ticket: EndpointTicket, token: ByteArray) {
        val address = ticket.endpointAddr()
        val active = withTimeout(PHASE_TIMEOUT_MS) { endpoint.connect(address, Wire.SESSION_ALPN) }
        address.close()
        connection = active
        val primary = withTimeout(PHASE_TIMEOUT_MS) { active.openBi() }
        val control = runCatching { withTimeout(PHASE_TIMEOUT_MS) { active.openBi() } }.getOrNull()
        val primarySend = primary.send()
        val primaryReceive = primary.recv()
        val controlSend = control?.send()
        val controlReceive = control?.recv()
        val outgoing = Channel<ByteArray>(
            capacity = OUTBOUND_CAPACITY,
            onBufferOverflow = BufferOverflow.DROP_LATEST,
        )
        try {
            withTimeout(PHASE_TIMEOUT_MS) {
                primarySend.writeAll(
                    Wire.encodeAttach(
                        token,
                        terminal.geometry.value.let {
                            Wire.Size(it.cols, it.rows, it.pixelWidth, it.pixelHeight)
                        },
                    ),
                )
            }
            coroutineScope {
                val writer = launch { writePump(outgoing, primarySend, controlSend, active) }
                val controlReader = controlReceive?.let { receive -> launch { readControl(receive, outgoing) } }
                try {
                    readPrimary(primaryReceive, token, outgoing)
                } finally {
                    outbound.compareAndSet(outgoing, null)
                    outgoing.close()
                    writer.cancel()
                    controlReader?.cancel()
                }
            }
        } finally {
            connection = null
            runCatching { active.close(0, "connection ended".encodeToByteArray()) }
            controlReceive?.close()
            controlSend?.close()
            primaryReceive.close()
            primarySend.close()
            control?.close()
            primary.close()
            active.close()
        }
    }

    private suspend fun writePump(
        outgoing: Channel<ByteArray>,
        primary: SendStream,
        initialControl: SendStream?,
        active: Connection,
    ) {
        var control = initialControl
        try {
            for (frame in outgoing) {
                if (Wire.isControlFrame(frame) && control != null) {
                    try {
                        control.writeAll(frame)
                        continue
                    } catch (_: Throwable) {
                        control.close()
                        control = null
                    }
                }
                primary.writeAll(frame)
            }
        } catch (error: Throwable) {
            runCatching { active.close(1, "write failed".encodeToByteArray()) }
            throw error
        } finally {
            runCatching { control?.finish() }
            runCatching { primary.finish() }
        }
    }

    private suspend fun readPrimary(
        receive: RecvStream,
        expectedToken: ByteArray,
        outgoing: Channel<ByteArray>,
    ) {
        val decoder = Wire.Decoder()
        var attached = false
        while (true) {
            val chunk = receive.read(READ_SIZE.toUInt())
            if (chunk.isEmpty()) {
                if (!attached) error("host closed before ATTACHED")
                return
            }
            decoder.append(chunk)
            for (frame in decoder.drain()) {
                when (frame.type) {
                    Wire.DATA -> {
                        check(attached) { "host sent terminal data before ATTACHED" }
                        val reply = terminal.feed(frame.payload)
                        if (reply.isNotEmpty()) sendInput(reply)
                    }
                    Wire.PING -> if (frame.payload.size == 8) outgoing.trySend(Wire.encode(Wire.PONG, frame.payload))
                    Wire.ATTACHED -> {
                        val echoed = Wire.parseAttached(frame.payload)
                            ?: error("host sent malformed ATTACHED")
                        check(echoed.contentEquals(expectedToken)) { "host echoed a different session token" }
                        if (!attached) {
                            attached = true
                            check(outbound.compareAndSet(null, outgoing)) { "another attachment is active" }
                            backoff.reset()
                            onStatus(SessionStatus.Connected)
                            onAttached()
                        }
                    }
                    Wire.ERROR -> {
                        val error = Wire.parseError(frame.payload)
                        throw PermanentRejection(
                            message = error?.message?.ifBlank { "Host rejected the connection" }
                                ?: "Host rejected the connection",
                            authorization = error?.code == Wire.ERROR_AUTHORIZATION,
                        )
                    }
                }
            }
        }
    }

    private suspend fun readControl(receive: RecvStream, outgoing: Channel<ByteArray>) {
        val decoder = Wire.Decoder()
        runCatching {
            while (true) {
                val chunk = receive.read(READ_SIZE.toUInt())
                if (chunk.isEmpty()) return
                decoder.append(chunk)
                decoder.drain().forEach { frame ->
                    if (frame.type == Wire.PING && frame.payload.size == 8) {
                        outgoing.trySend(Wire.encode(Wire.PONG, frame.payload))
                    }
                }
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        job?.cancel()
        job = null
        outbound.getAndSet(null)?.close()
        connection?.runCatching { close(0, "disconnected".encodeToByteArray()) }
        connection = null
    }

    private class PermanentRejection(message: String, val authorization: Boolean) : Exception(message)

    private fun Throwable.safeMessage(): String =
        message?.take(240)?.takeIf(String::isNotBlank) ?: javaClass.simpleName

    private companion object {
        const val OUTBOUND_CAPACITY = 256
        const val PHASE_TIMEOUT_MS = 20_000L
        const val READ_SIZE = 16 * 1024
    }
}

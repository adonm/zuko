package dev.adonm.zuko.net

import android.os.Build
import computer.iroh.Connection
import computer.iroh.Endpoint
import computer.iroh.EndpointAddr
import computer.iroh.EndpointOptions
import computer.iroh.EndpointTicket
import computer.iroh.SecretKey
import computer.iroh.presetN0
import dev.adonm.zuko.core.ClientIdentity
import dev.adonm.zuko.core.PairingCode
import dev.adonm.zuko.core.SavedHost
import dev.adonm.zuko.core.Wire
import dev.adonm.zuko.ffi.deriveHandoffKey
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.coroutineContext

enum class ClaimStage(val message: String) {
    DERIVING("Deriving pairing key…"),
    DIALING("Reaching the host…"),
    READING("Receiving ticket…"),
    AUTHORIZING("Saving and authorizing…"),
}

class ClaimClient {
    suspend fun claim(
        rawCode: String,
        clientSeed: ByteArray,
        expectedNodeId: String? = null,
        onStage: (ClaimStage) -> Unit,
        persist: (SavedHost) -> Unit,
    ): SavedHost {
        val code = PairingCode.parse(rawCode) ?: error("Enter the two-word code shown by `zuko share`.")
        onStage(ClaimStage.DERIVING)
        val handoffSeed = deriveHandoffKey(code)
        val targetId = SecretKey.fromBytes(handoffSeed).use { it.public() }
        val address = EndpointAddr(targetId, null, emptyList())
        targetId.close()
        val endpoint = try {
            Endpoint.bind(EndpointOptions(preset = presetN0()))
        } catch (error: Throwable) {
            address.close()
            throw error
        }
        var connection: Connection? = null
        try {
            withTimeout(CLAIM_TIMEOUT_MS) { endpoint.online() }
            onStage(ClaimStage.DIALING)
            connection = address.use { dialWithRetry(endpoint, it) }
            onStage(ClaimStage.READING)
            val payload = connection.acceptUni().use { receive -> receive.readToEnd(MAX_HANDOFF_BYTES.toUInt()) }
            val text = strictUtf8(payload)
            val newline = text.indexOf('\n')
            val hostLabel = if (newline < 0) "host" else text.substring(0, newline).trim().ifEmpty { "host" }
            val ticketString = (if (newline < 0) text else text.substring(newline + 1)).trim()
            check(ticketString.isNotEmpty()) { "The host returned an empty ticket." }

            EndpointTicket.fromString(ticketString).use { ticket ->
                val nodeId = ticket.endpointAddr().use { it.id().use(Any::toString) }
                check(expectedNodeId == null || nodeId == expectedNodeId) {
                    "That code belongs to a different host."
                }
                val clientLabel = ClientIdentity.authorizationLabel(Build.MODEL.orEmpty(), hostLabel)
                val host = SavedHost(
                    id = UUID.randomUUID().toString(),
                    label = hostLabel,
                    ticket = ticketString,
                    nodeId = nodeId,
                    addedAtEpochMillis = System.currentTimeMillis(),
                    authorizedClientLabel = clientLabel,
                )
                onStage(ClaimStage.AUTHORIZING)
                // Once local persistence starts, finish authorization even if
                // the calling screen is dismissed. The host's one-shot share
                // may exit after this connection closes, so cancellation here
                // could otherwise leave a saved but unauthorized host.
                withContext(NonCancellable) {
                    persist(host)

                    val token = ClientIdentity.sessionToken(clientSeed, nodeId)
                    withTimeout(AUTHORIZE_SEND_TIMEOUT_MS) {
                        connection.openUni().use { send ->
                            send.writeAll(Wire.encodeAuthorize(token, clientLabel))
                            send.finish()
                            // Keep the handoff connection alive briefly so the host can
                            // read and persist AUTHORIZE before this one-shot claim exits.
                            withTimeoutOrNull(AUTHORIZE_DRAIN_TIMEOUT_MS) {
                                runCatching { send.stopped() }
                            }
                        }
                    }
                }
                return host
            }
        } finally {
            connection?.runCatching { close(0, "claimed".encodeToByteArray()) }
            runCatching { endpoint.shutdown() }
            connection?.close()
            endpoint.close()
        }
    }

    private suspend fun dialWithRetry(endpoint: Endpoint, address: EndpointAddr): Connection =
        withTimeout(CLAIM_TIMEOUT_MS) {
            var last: Throwable? = null
            while (true) {
                coroutineContext.ensureActive()
                try {
                    return@withTimeout endpoint.connect(address, Wire.HANDOFF_ALPN)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    last = error
                    delay(DIAL_RETRY_MS)
                }
            }
            @Suppress("UNREACHABLE_CODE")
            throw last ?: IllegalStateException("pairing timed out")
        }

    private fun strictUtf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes))
        .toString()

    private companion object {
        const val MAX_HANDOFF_BYTES = 8 * 1024
        const val CLAIM_TIMEOUT_MS = 60_000L
        const val AUTHORIZE_SEND_TIMEOUT_MS = 20_000L
        const val AUTHORIZE_DRAIN_TIMEOUT_MS = 2_000L
        const val DIAL_RETRY_MS = 2_000L
    }
}

package dev.adonm.zuko.core

import java.io.ByteArrayOutputStream

/** Zuko protocol v2 framing and payload codecs. */
object Wire {
    val SESSION_ALPN = "zuko/2".encodeToByteArray()
    val HANDOFF_ALPN = "zuko/handoff/1".encodeToByteArray()

    const val DATA = 0x00
    const val RESIZE = 0x01
    const val PING = 0x04
    const val PONG = 0x05
    const val ATTACH = 0x06
    const val ATTACHED = 0x07
    const val AUTHORIZE = 0x08
    const val ERROR = 0x09

    const val ERROR_AUTHORIZATION = 0x01
    const val ERROR_PROTOCOL = 0x02
    const val SESSION_TOKEN_LENGTH = 16
    const val MAX_PAYLOAD = 65_535

    data class Frame(val type: Int, val payload: ByteArray)
    data class Size(val cols: Int, val rows: Int, val pixelWidth: Int, val pixelHeight: Int)
    data class ErrorPayload(val code: Int, val message: String)

    fun encode(type: Int, payload: ByteArray = byteArrayOf()): ByteArray {
        require(type in 0..255) { "frame type must fit in u8" }
        require(payload.size <= MAX_PAYLOAD) { "payload exceeds $MAX_PAYLOAD bytes" }
        return ByteArray(payload.size + 3).also { out ->
            out[0] = type.toByte()
            putU16(out, 1, payload.size)
            payload.copyInto(out, destinationOffset = 3)
        }
    }

    fun encodeData(data: ByteArray): List<ByteArray> =
        if (data.isEmpty()) {
            listOf(encode(DATA))
        } else {
            data.asList().chunked(MAX_PAYLOAD).map { encode(DATA, it.toByteArray()) }
        }

    fun encodeResize(size: Size): ByteArray = encode(RESIZE, resizePayload(size))

    fun encodeAttach(token: ByteArray, size: Size): ByteArray {
        requireToken(token)
        return encode(ATTACH, token + resizePayload(size))
    }

    fun encodeAttached(token: ByteArray): ByteArray {
        requireToken(token)
        return encode(ATTACHED, token)
    }

    fun encodeAuthorize(token: ByteArray, label: String): ByteArray {
        requireToken(token)
        val encoded = label.encodeToByteArray()
        require(encoded.size <= MAX_PAYLOAD - SESSION_TOKEN_LENGTH) { "authorization label is too long" }
        return encode(AUTHORIZE, token + encoded)
    }

    fun encodeError(code: Int, message: String): ByteArray {
        require(code in 0..255)
        val encoded = message.encodeToByteArray()
        require(encoded.size <= MAX_PAYLOAD - 1) { "error message is too long" }
        return encode(ERROR, byteArrayOf(code.toByte()) + encoded)
    }

    fun encodePing(type: Int, nonce: Long): ByteArray {
        require(type == PING || type == PONG)
        return encode(type, ByteArray(8).also { putU64(it, nonce) })
    }

    fun parseResize(payload: ByteArray): Size? {
        if (payload.size != 8) return null
        return Size(
            cols = u16(payload, 0),
            rows = u16(payload, 2),
            pixelWidth = u16(payload, 4),
            pixelHeight = u16(payload, 6),
        )
    }

    fun parseAttached(payload: ByteArray): ByteArray? =
        payload.takeIf { it.size == SESSION_TOKEN_LENGTH }?.copyOf()

    fun parseError(payload: ByteArray): ErrorPayload? =
        payload.takeIf { it.isNotEmpty() }?.let {
            ErrorPayload(it[0].toInt() and 0xff, it.copyOfRange(1, it.size).decodeToString())
        }

    fun isControlFrame(frame: ByteArray): Boolean =
        frame.firstOrNull()?.toInt()?.and(0xff) in setOf(RESIZE, PING, PONG)

    private fun resizePayload(size: Size): ByteArray {
        require(size.cols in 1..65_535 && size.rows in 1..65_535) { "cell size must be non-zero u16" }
        require(size.pixelWidth in 0..65_535 && size.pixelHeight in 0..65_535) { "pixel size must fit in u16" }
        return ByteArray(8).also {
            putU16(it, 0, size.cols)
            putU16(it, 2, size.rows)
            putU16(it, 4, size.pixelWidth)
            putU16(it, 6, size.pixelHeight)
        }
    }

    private fun requireToken(token: ByteArray) {
        require(token.size == SESSION_TOKEN_LENGTH) { "session token must be $SESSION_TOKEN_LENGTH bytes" }
        require(token.any { it.toInt() != 0 }) { "session token must not be all-zero" }
    }

    private fun putU16(out: ByteArray, offset: Int, value: Int) {
        out[offset] = (value ushr 8).toByte()
        out[offset + 1] = value.toByte()
    }

    private fun u16(input: ByteArray, offset: Int): Int =
        ((input[offset].toInt() and 0xff) shl 8) or (input[offset + 1].toInt() and 0xff)

    private fun putU64(out: ByteArray, value: Long) {
        for (index in 0 until 8) out[index] = (value ushr (56 - index * 8)).toByte()
    }

    class Decoder(private val compactThreshold: Int = 64 * 1024) {
        private var buffer = ByteArray(0)
        private var start = 0

        val pendingByteCount: Int get() = buffer.size - start

        fun append(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset) {
            require(offset >= 0 && length >= 0 && offset + length <= bytes.size)
            if (length == 0) return
            val pending = pendingByteCount
            val next = ByteArray(pending + length)
            buffer.copyInto(next, endIndex = buffer.size, startIndex = start)
            bytes.copyInto(next, destinationOffset = pending, startIndex = offset, endIndex = offset + length)
            buffer = next
            start = 0
        }

        fun next(): Frame? {
            if (pendingByteCount < 3) return null
            val length = u16(buffer, start + 1)
            if (pendingByteCount < 3 + length) return null
            val frame = Frame(
                type = buffer[start].toInt() and 0xff,
                payload = buffer.copyOfRange(start + 3, start + 3 + length),
            )
            start += 3 + length
            compactIfNeeded()
            return frame
        }

        fun drain(): List<Frame> = buildList {
            while (true) add(next() ?: break)
        }

        private fun compactIfNeeded() {
            if (start == buffer.size) {
                buffer = ByteArray(0)
                start = 0
            } else if (start >= compactThreshold) {
                buffer = buffer.copyOfRange(start, buffer.size)
                start = 0
            }
        }
    }
}

private fun List<Byte>.toByteArray(): ByteArray = ByteArray(size) { this[it] }

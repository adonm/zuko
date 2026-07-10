package dev.adonm.zuko.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WireTest {
    @Test fun `data frame round trips`() {
        val encoded = Wire.encode(Wire.DATA, "hello".encodeToByteArray())
        assertContentEquals(byteArrayOf(0, 0, 5, 0x68, 0x65, 0x6c, 0x6c, 0x6f), encoded)
        val decoder = Wire.Decoder().also { it.append(encoded) }
        assertEquals(Wire.DATA, decoder.next()?.type)
        assertEquals(0, decoder.pendingByteCount)
    }

    @Test fun `resize has canonical big endian layout`() {
        val encoded = Wire.encodeResize(Wire.Size(0x1234, 0x5678, 0, 0))
        assertContentEquals(
            byteArrayOf(1, 0, 8, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0),
            encoded,
        )
        assertEquals(Wire.Size(0x1234, 0x5678, 0, 0), Wire.parseResize(encoded.copyOfRange(3, 11)))
    }

    @Test fun `attach authorize and error have canonical layouts`() {
        val token = ByteArray(16) { it.toByte() }
        val attach = Wire.encodeAttach(token, Wire.Size(80, 24, 1080, 1920))
        assertEquals(27, attach.size)
        assertContentEquals(token, attach.copyOfRange(3, 19))
        assertContentEquals(byteArrayOf(0, 80, 0, 24, 4, 56, 7, 0x80.toByte()), attach.copyOfRange(19, 27))

        val authorize = Wire.encodeAuthorize(token, "phone")
        assertContentEquals(token + "phone".encodeToByteArray(), authorize.copyOfRange(3, authorize.size))
        assertEquals(
            Wire.ErrorPayload(Wire.ERROR_AUTHORIZATION, "not authorised"),
            Wire.parseError(Wire.encodeError(Wire.ERROR_AUTHORIZATION, "not authorised").copyOfRange(3, 18)),
        )
    }

    @Test fun `decoder preserves incomplete input`() {
        val frame = Wire.encode(Wire.DATA, "hello".encodeToByteArray())
        val decoder = Wire.Decoder()
        decoder.append(frame, length = frame.size - 1)
        assertNull(decoder.next())
        assertEquals(frame.size - 1, decoder.pendingByteCount)
        decoder.append(frame, offset = frame.size - 1, length = 1)
        assertEquals("hello", decoder.next()?.payload?.decodeToString())
    }

    @Test fun `decoder drains back-to-back and chunked frames`() {
        val decoder = Wire.Decoder(compactThreshold = 64)
        val expected = (0 until 500).map { (it and 0xff).toByte() }
        val bytes = expected.flatMap { Wire.encode(Wire.DATA, byteArrayOf(it)).asIterable() }.toByteArray()
        bytes.forEach { decoder.append(byteArrayOf(it)) }
        assertEquals(expected, decoder.drain().map { it.payload.single() })
        assertEquals(0, decoder.pendingByteCount)
    }

    @Test fun `unknown frames are consumed`() {
        val decoder = Wire.Decoder().also { it.append(Wire.encode(0x7f, "payload".encodeToByteArray())) }
        assertEquals(0x7f, decoder.next()?.type)
        assertEquals(0, decoder.pendingByteCount)
    }

    @Test fun `attached rejects wrong lengths and control types are exact`() {
        assertNull(Wire.parseAttached(ByteArray(15)))
        assertNull(Wire.parseAttached(ByteArray(17)))
        assertContentEquals(ByteArray(16) { 1 }, Wire.parseAttached(ByteArray(16) { 1 }))
        assertTrue(Wire.isControlFrame(Wire.encodeResize(Wire.Size(1, 1, 0, 0))))
        assertTrue(Wire.isControlFrame(Wire.encodePing(Wire.PING, 42)))
        assertFalse(Wire.isControlFrame(Wire.encode(Wire.DATA)))
        assertFalse(Wire.isControlFrame(byteArrayOf()))
    }
}

private fun List<Byte>.toByteArray(): ByteArray = ByteArray(size) { this[it] }

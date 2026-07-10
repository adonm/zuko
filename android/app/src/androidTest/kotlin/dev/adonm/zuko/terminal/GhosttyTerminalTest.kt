package dev.adonm.zuko.terminal

import android.view.KeyEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import computer.iroh.SecretKey
import dev.adonm.zuko.ffi.deriveHandoffKey
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GhosttyTerminalTest {
    @Test
    fun loadsRustFfiLibrariesAndMatchesHandoffVector() {
        val seed = deriveHandoffKey("iridescent-hilton")
        assertEquals(32, seed.size)
        assertArrayEquals(
            byteArrayOf(
                0x52, 0x83.toByte(), 0xf4.toByte(), 0xc1.toByte(), 0x4a, 0xfc.toByte(), 0xfa.toByte(), 0xb6.toByte(),
                0x36, 0x41, 0xcd.toByte(), 0x2e, 0x49, 0x61, 0xe9.toByte(), 0x31,
                0x88.toByte(), 0x89.toByte(), 0xde.toByte(), 0xe8.toByte(), 0xce.toByte(), 0x65, 0x07, 0x8b.toByte(),
                0x56, 0xd3.toByte(), 0x7d, 0x82.toByte(), 0x41, 0x18, 0x80.toByte(), 0x8e.toByte(),
            ),
            seed,
        )
        SecretKey.fromBytes(seed).use { secret ->
            secret.public().use { public -> assertTrue(public.toString().isNotBlank()) }
        }
    }

    @Test
    fun parsesVtSnapshotsAndEncodesModeAwareKeys() {
        GhosttyTerminal(initialCols = 20, initialRows = 3).use { terminal ->
            val replies = terminal.feed("hello\r\n\u001b[31mred\u001b[0m".encodeToByteArray())
            assertTrue(replies.isEmpty())
            assertTrue(terminal.screen.value.lineSequence().first() == "hello")
            assertTrue(terminal.screen.value.contains("red"))

            assertArrayEquals(
                "\u001b[A".encodeToByteArray(),
                terminal.encodeKey(KeyEvent.KEYCODE_DPAD_UP),
            )
            terminal.resize(40, 8, 8, 16)
            assertTrue(terminal.geometry.value.cols == 40)
        }
    }
}

package dev.adonm.zuko.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PairingCodeTest {
    @Test fun `parses plain path and query forms`() {
        assertEquals("iridescent-hilton", PairingCode.parse("iridescent-hilton"))
        assertEquals("iridescent-hilton", PairingCode.parse("zuko://pair/iridescent-hilton"))
        assertEquals("IRIDESCENT HILTON", PairingCode.parse("zuko://pair?code=IRIDESCENT%20HILTON"))
    }

    @Test fun `accepts human formatting`() {
        assertEquals("IRIDESCENT HILTON", PairingCode.parse("  IRIDESCENT HILTON  "))
        assertEquals("iridescent_hilton", PairingCode.parse("iridescent_hilton"))
        assertEquals("iridescenthilton", PairingCode.parse("iridescenthilton"))
    }

    @Test fun `rejects wrong links and non-ascii material`() {
        listOf(
            "https://pair/code",
            "zuko://other/code",
            "zuko://pair/",
            "abc123",
            "schön-host",
            "a".repeat(129),
        ).forEach { assertNull(PairingCode.parse(it), it) }
    }
}

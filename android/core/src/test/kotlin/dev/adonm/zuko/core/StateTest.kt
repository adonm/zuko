package dev.adonm.zuko.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class StateTest {
    @Test fun `backoff caps and resets`() {
        val backoff = ReconnectBackoff()
        assertEquals(listOf(1, 2, 4, 8, 15, 15, 15), List(7) { backoff.recordFailure().delaySeconds })
        backoff.reset()
        assertEquals(ReconnectBackoff.Step(1, 1), backoff.recordFailure())
    }

    @Test fun `client token matches captured vector`() {
        val seed = ByteArray(32) { it.toByte() }
        assertContentEquals(
            "7ef18ae76a62845e41c9eabeb4f43c7f".hexToBytes(),
            ClientIdentity.sessionToken(seed, "host-id"),
        )
    }

    @Test fun `hosts deduplicate promote and cap`() {
        val original = host(1, nodeId = "same", label = "Old")
        val replacement = host(2, nodeId = "same", label = " New ")
        val merged = SavedHosts.upsert(listOf(original), replacement).single()
        assertEquals(original.id, merged.id)
        assertEquals(original.addedAtEpochMillis, merged.addedAtEpochMillis)
        assertEquals("New", merged.label)

        val many = (0..12).fold(emptyList<SavedHost>()) { hosts, index ->
            SavedHosts.upsert(hosts, host(index, nodeId = "node-$index"))
        }
        assertEquals(12, many.size)
        assertEquals("node-12", many.first().nodeId)
        assertEquals("node-1", many.last().nodeId)
    }

    private fun host(index: Int, nodeId: String, label: String = "Host $index") = SavedHost(
        id = "id-$index",
        label = label,
        ticket = "ticket-$index",
        nodeId = nodeId,
        addedAtEpochMillis = index.toLong(),
    )
}

private fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()

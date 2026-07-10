package dev.adonm.zuko.core

import java.util.UUID

data class SavedHost(
    val id: String = UUID.randomUUID().toString(),
    val label: String,
    val ticket: String,
    val nodeId: String,
    val addedAtEpochMillis: Long,
    val lastConnectedAtEpochMillis: Long? = null,
    val authorizedClientLabel: String? = null,
) {
    fun normalized(): SavedHost = copy(label = label.trim().ifEmpty { "Host" })
}

object SavedHosts {
    const val MAX_HOSTS = 12

    fun upsert(current: List<SavedHost>, incoming: SavedHost): List<SavedHost> {
        val previous = current.firstOrNull { it.nodeId == incoming.nodeId }
        val saved = incoming.normalized().let { next ->
            if (previous == null) next else next.copy(
                id = previous.id,
                addedAtEpochMillis = previous.addedAtEpochMillis,
                lastConnectedAtEpochMillis = previous.lastConnectedAtEpochMillis,
            )
        }
        return (listOf(saved) + current.filterNot { it.nodeId == saved.nodeId }).take(MAX_HOSTS)
    }

    fun markConnected(current: List<SavedHost>, id: String, atEpochMillis: Long): List<SavedHost> {
        val host = current.firstOrNull { it.id == id } ?: return current
        return listOf(host.copy(lastConnectedAtEpochMillis = atEpochMillis)) + current.filterNot { it.id == id }
    }
}

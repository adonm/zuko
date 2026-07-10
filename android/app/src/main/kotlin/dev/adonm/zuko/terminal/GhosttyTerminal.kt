package dev.adonm.zuko.terminal

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal object GhosttyNative {
    init {
        System.loadLibrary("zuko_terminal")
    }

    external fun nativeCreate(cols: Int, rows: Int, scrollback: Long): Long
    external fun nativeClose(handle: Long)
    external fun nativeFeed(handle: Long, data: ByteArray): ByteArray
    external fun nativeResize(handle: Long, cols: Int, rows: Int, cellWidth: Int, cellHeight: Int): ByteArray
    external fun nativeScroll(handle: Long, rows: Int)
    external fun nativeSnapshot(handle: Long): ByteArray
    external fun nativeEncodeKey(handle: Long, androidKeyCode: Int, modifiers: Int, text: ByteArray?): ByteArray
}

class GhosttyTerminal(
    initialCols: Int = 80,
    initialRows: Int = 24,
) : AutoCloseable {
    data class Geometry(
        val cols: Int,
        val rows: Int,
        val cellWidthPx: Int,
        val cellHeightPx: Int,
    ) {
        val pixelWidth: Int get() = (cols.toLong() * cellWidthPx).coerceAtMost(65_535).toInt()
        val pixelHeight: Int get() = (rows.toLong() * cellHeightPx).coerceAtMost(65_535).toInt()
    }

    private var handle = GhosttyNative.nativeCreate(initialCols, initialRows, 10_000)
    private val _screen = MutableStateFlow("")
    private val _geometry = MutableStateFlow(Geometry(initialCols, initialRows, 8, 16))
    val screen: StateFlow<String> = _screen.asStateFlow()
    val geometry: StateFlow<Geometry> = _geometry.asStateFlow()

    @Synchronized
    fun feed(data: ByteArray): ByteArray = withHandle { current ->
        GhosttyNative.nativeFeed(current, data).also { refresh(current) }
    }

    @Synchronized
    fun resize(cols: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int): ByteArray = withHandle { current ->
        val geometry = Geometry(
            cols.coerceIn(1, 65_535),
            rows.coerceIn(1, 65_535),
            cellWidthPx.coerceAtLeast(1),
            cellHeightPx.coerceAtLeast(1),
        )
        _geometry.value = geometry
        GhosttyNative.nativeResize(
            current,
            geometry.cols,
            geometry.rows,
            geometry.cellWidthPx,
            geometry.cellHeightPx,
        ).also { refresh(current) }
    }

    @Synchronized
    fun scroll(rows: Int) = withHandle { current ->
        GhosttyNative.nativeScroll(current, rows)
        refresh(current)
    }

    @Synchronized
    fun encodeKey(androidKeyCode: Int, modifiers: Int = 0, text: ByteArray? = null): ByteArray =
        withHandle { GhosttyNative.nativeEncodeKey(it, androidKeyCode, modifiers, text) }

    @Synchronized
    override fun close() {
        val current = handle
        if (current != 0L) {
            handle = 0
            GhosttyNative.nativeClose(current)
        }
    }

    private fun refresh(current: Long) {
        _screen.value = GhosttyNative.nativeSnapshot(current).decodeToString()
    }

    private inline fun <T> withHandle(block: (Long) -> T): T {
        check(handle != 0L) { "terminal is closed" }
        return block(handle)
    }

    companion object {
        const val MOD_SHIFT = 1
        const val MOD_CTRL = 1 shl 1
        const val MOD_ALT = 1 shl 2
    }
}

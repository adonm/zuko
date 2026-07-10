package dev.adonm.zuko.core

class ReconnectBackoff {
    data class Step(val attempt: Int, val delaySeconds: Int)

    var attempt: Int = 0
        private set

    fun recordFailure(): Step {
        attempt += 1
        val delay = when (attempt) {
            1 -> 1
            2 -> 2
            3 -> 4
            4 -> 8
            else -> 15
        }
        return Step(attempt, delay)
    }

    fun reset() {
        attempt = 0
    }
}

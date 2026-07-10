package dev.adonm.zuko.core

import java.security.MessageDigest

object ClientIdentity {
    private val DOMAIN = "zuko-ios-session-token-v1".encodeToByteArray()

    fun sessionToken(seed: ByteArray, hostId: String): ByteArray {
        require(seed.size == 32) { "client seed must be 32 bytes" }
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(DOMAIN)
        digest.update(seed)
        digest.update(hostId.encodeToByteArray())
        return digest.digest().copyOf(Wire.SESSION_TOKEN_LENGTH).also { token ->
            check(token.any { it.toInt() != 0 }) { "derived all-zero session token" }
        }
    }

    fun authorizationLabel(deviceName: String, fallback: String): String {
        val cleaned = deviceName.trim().map { if (it.isWhitespace()) '-' else it }.joinToString("").trim('-')
        return cleaned.takeUnless { it.isEmpty() || it.startsWith('#') } ?: fallback
    }
}

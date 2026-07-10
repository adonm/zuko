package dev.adonm.zuko.core

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

object PairingCode {
    fun parse(input: String): String? {
        val trimmed = input.trim()
        val candidate = if (trimmed.startsWith("zuko://", ignoreCase = true)) {
            parseUri(trimmed) ?: return null
        } else {
            trimmed
        }
        return candidate.trim().takeIf(::isValid)
    }

    fun isValid(candidate: String): Boolean {
        if (candidate.length !in 3..128 || candidate.none { it.isAsciiLetter() }) return false
        return candidate.all { it.isAsciiLetter() || it == '-' || it == '_' || it == ' ' }
    }

    private fun parseUri(value: String): String? {
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (!uri.scheme.equals("zuko", ignoreCase = true) || !uri.host.equals("pair", ignoreCase = true)) return null
        val queryCode = uri.rawQuery
            ?.split('&')
            ?.mapNotNull { field ->
                val parts = field.split('=', limit = 2)
                if (parts.firstOrNull() == "code") parts.getOrNull(1) else null
            }
            ?.firstOrNull()
        val pathCode = uri.rawPath?.removePrefix("/")?.takeIf { it.isNotEmpty() }
        val encoded = queryCode ?: pathCode ?: return null
        return runCatching { URLDecoder.decode(encoded, StandardCharsets.UTF_8) }.getOrNull()
    }

    private fun Char.isAsciiLetter(): Boolean = this in 'a'..'z' || this in 'A'..'Z'
}

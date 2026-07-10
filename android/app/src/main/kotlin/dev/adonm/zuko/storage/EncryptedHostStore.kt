package dev.adonm.zuko.storage

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import dev.adonm.zuko.core.SavedHost
import dev.adonm.zuko.core.SavedHosts
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Keystore-encrypted, atomic, non-backed-up mobile client state. */
class EncryptedHostStore(context: Context) {
    data class State(val clientSeed: ByteArray, val hosts: List<SavedHost>)

    private val file = AtomicFile(context.noBackupFilesDir.resolve(FILE_NAME))
    private val random = SecureRandom()

    @Synchronized
    fun loadOrCreate(): State {
        if (!file.baseFile.exists()) {
            val state = State(ByteArray(SEED_LENGTH).also(random::nextBytes), emptyList())
            write(state)
            return state.copy(clientSeed = state.clientSeed.copyOf())
        }
        return decode(decrypt(file.readFully()))
    }

    @Synchronized
    fun upsert(host: SavedHost): State {
        val current = loadOrCreate()
        val next = current.copy(hosts = SavedHosts.upsert(current.hosts, host))
        write(next)
        return next
    }

    @Synchronized
    fun markConnected(id: String, atEpochMillis: Long): State {
        val current = loadOrCreate()
        val next = current.copy(hosts = SavedHosts.markConnected(current.hosts, id, atEpochMillis))
        if (next != current) write(next)
        return next
    }

    @Synchronized
    fun forget(id: String): State {
        val current = loadOrCreate()
        val next = current.copy(hosts = current.hosts.filterNot { it.id == id })
        if (next != current) write(next)
        return next
    }

    private fun write(state: State) {
        val bytes = encrypt(encode(state))
        val output = file.startWrite()
        try {
            output.write(bytes)
            file.finishWrite(output)
        } catch (error: Throwable) {
            file.failWrite(output)
            throw error
        }
    }

    private fun encode(state: State): ByteArray = ByteArrayOutputStream().use { bytes ->
        DataOutputStream(bytes).use { output ->
            require(state.clientSeed.size == SEED_LENGTH)
            output.writeInt(INNER_MAGIC)
            output.writeInt(FORMAT_VERSION)
            output.write(state.clientSeed)
            output.writeInt(state.hosts.size)
            state.hosts.forEach { host ->
                output.writeUTF(host.id)
                output.writeUTF(host.label)
                output.writeUTF(host.ticket)
                output.writeUTF(host.nodeId)
                output.writeLong(host.addedAtEpochMillis)
                output.writeBoolean(host.lastConnectedAtEpochMillis != null)
                host.lastConnectedAtEpochMillis?.let(output::writeLong)
                output.writeBoolean(host.authorizedClientLabel != null)
                host.authorizedClientLabel?.let(output::writeUTF)
            }
        }
        bytes.toByteArray()
    }

    private fun decode(bytes: ByteArray): State = DataInputStream(ByteArrayInputStream(bytes)).use { input ->
        check(input.readInt() == INNER_MAGIC) { "invalid encrypted state magic" }
        check(input.readInt() == FORMAT_VERSION) { "unsupported encrypted state version" }
        val seed = ByteArray(SEED_LENGTH).also(input::readFully)
        val count = input.readInt()
        check(count in 0..SavedHosts.MAX_HOSTS) { "invalid host count" }
        val hosts = List(count) {
            SavedHost(
                id = input.readUTF(),
                label = input.readUTF(),
                ticket = input.readUTF(),
                nodeId = input.readUTF(),
                addedAtEpochMillis = input.readLong(),
                lastConnectedAtEpochMillis = if (input.readBoolean()) input.readLong() else null,
                authorizedClientLabel = if (input.readBoolean()) input.readUTF() else null,
            )
        }
        check(input.available() == 0) { "trailing encrypted state data" }
        State(seed, hosts)
    }

    private fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(plaintext)
        return ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(OUTER_MAGIC)
                output.writeInt(cipher.iv.size)
                output.write(cipher.iv)
                output.writeInt(ciphertext.size)
                output.write(ciphertext)
            }
            bytes.toByteArray()
        }
    }

    private fun decrypt(encrypted: ByteArray): ByteArray =
        DataInputStream(ByteArrayInputStream(encrypted)).use { input ->
            check(input.readInt() == OUTER_MAGIC) { "invalid encrypted envelope" }
            val nonceLength = input.readInt()
            check(nonceLength == GCM_NONCE_LENGTH) { "invalid encrypted nonce" }
            val nonce = ByteArray(nonceLength).also(input::readFully)
            val ciphertextLength = input.readInt()
            check(ciphertextLength in 16..MAX_ENCRYPTED_BYTES) { "invalid encrypted payload size" }
            val ciphertext = ByteArray(ciphertextLength).also(input::readFully)
            check(input.available() == 0) { "trailing encrypted envelope data" }
            Cipher.getInstance(TRANSFORMATION).run {
                init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, nonce))
                doFinal(ciphertext)
            }
        }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .setUserAuthenticationRequired(false)
                    .build(),
            )
            generateKey()
        }
    }

    private companion object {
        const val FILE_NAME = "mobile-state.enc"
        const val KEY_ALIAS = "zuko-mobile-state-v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_NONCE_LENGTH = 12
        const val SEED_LENGTH = 32
        const val MAX_ENCRYPTED_BYTES = 1024 * 1024
        const val FORMAT_VERSION = 1
        const val OUTER_MAGIC = 0x5A554B45
        const val INNER_MAGIC = 0x5A554B4F
    }
}

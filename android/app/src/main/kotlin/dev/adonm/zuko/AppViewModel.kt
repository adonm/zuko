package dev.adonm.zuko

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.adonm.zuko.core.PairingCode
import dev.adonm.zuko.core.SavedHost
import dev.adonm.zuko.net.ClaimClient
import dev.adonm.zuko.net.ClaimStage
import dev.adonm.zuko.net.IrohSession
import dev.adonm.zuko.net.SessionStatus
import dev.adonm.zuko.storage.EncryptedHostStore
import dev.adonm.zuko.terminal.GhosttyTerminal
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class AppUiState(
    val loading: Boolean = true,
    val hosts: List<SavedHost> = emptyList(),
    val pairing: Boolean = false,
    val pairingCode: String = "",
    val pairingMessage: String? = null,
    val pairingError: String? = null,
    val pairingCancelable: Boolean = true,
    val selectedHost: SavedHost? = null,
    val sessionStatus: SessionStatus = SessionStatus.Idle,
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val store = EncryptedHostStore(application)
    private val claimClient = ClaimClient()
    private val _state = MutableStateFlow(AppUiState())
    val state: StateFlow<AppUiState> = _state.asStateFlow()

    private var stored: EncryptedHostStore.State? = null
    private var claimJob: Job? = null
    private var expectedPairingNodeId: String? = null
    var terminal: GhosttyTerminal? = null
        private set
    private var session: IrohSession? = null

    init {
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { store.loadOrCreate() } }
                .onSuccess {
                    stored = it
                    _state.value = _state.value.copy(loading = false, hosts = it.hosts)
                }
                .onFailure {
                    _state.value = _state.value.copy(
                        loading = false,
                        pairingError = "Secure storage is unavailable: ${it.safeMessage()}",
                    )
                }
        }
    }

    fun beginPairing(prefill: String = "", expectedNodeId: String? = null) {
        expectedPairingNodeId = expectedNodeId
        _state.value = _state.value.copy(
            pairing = true,
            pairingCode = PairingCode.parse(prefill) ?: prefill,
            pairingMessage = null,
            pairingError = null,
            pairingCancelable = true,
        )
    }

    fun updatePairingCode(value: String) {
        _state.value = _state.value.copy(pairingCode = value, pairingError = null)
    }

    fun cancelPairing() {
        if (!_state.value.pairingCancelable) return
        claimJob?.cancel()
        expectedPairingNodeId = null
        _state.value = _state.value.copy(pairing = false, pairingMessage = null, pairingError = null)
    }

    fun submitPairing() {
        val current = stored ?: return
        if (claimJob != null) return
        val expectedNodeId = expectedPairingNodeId
        claimJob = viewModelScope.launch {
            _state.value = _state.value.copy(pairingError = null)
            try {
                val host = withContext(Dispatchers.IO) {
                    claimClient.claim(
                        rawCode = _state.value.pairingCode,
                        clientSeed = current.clientSeed,
                        expectedNodeId = expectedNodeId,
                        onStage = { stage ->
                            _state.value = _state.value.copy(
                                pairingMessage = stage.message,
                                pairingCancelable = stage != ClaimStage.AUTHORIZING,
                            )
                        },
                        persist = { saved ->
                            val next = store.upsert(saved)
                            stored = next
                            _state.value = _state.value.copy(hosts = next.hosts)
                        },
                    )
                }
                expectedPairingNodeId = null
                _state.value = _state.value.copy(pairing = false, pairingMessage = null)
                openHost(stored?.hosts?.firstOrNull { it.nodeId == host.nodeId } ?: host)
            } catch (error: Throwable) {
                if (claimJob?.isCancelled != true) {
                    _state.value = _state.value.copy(
                        pairingMessage = null,
                        pairingError = error.safeMessage(),
                        pairingCancelable = true,
                    )
                }
            } finally {
                claimJob = null
            }
        }
    }

    fun openHost(host: SavedHost) {
        disconnect()
        val clientSeed = stored?.clientSeed ?: return
        val ghostty = GhosttyTerminal()
        terminal = ghostty
        val active = IrohSession(
            scope = viewModelScope,
            terminal = ghostty,
            onStatus = { status -> _state.value = _state.value.copy(sessionStatus = status) },
            onAttached = {
                viewModelScope.launch(Dispatchers.IO) {
                    val next = store.markConnected(host.id, System.currentTimeMillis())
                    stored = next
                    _state.value = _state.value.copy(hosts = next.hosts)
                }
            },
        )
        session = active
        _state.value = _state.value.copy(selectedHost = host, sessionStatus = SessionStatus.Connecting)
        active.start(host, clientSeed)
    }

    fun sendInput(bytes: ByteArray) = session?.sendInput(bytes)
    fun sendKey(keyCode: Int, modifiers: Int = 0) = session?.sendKey(keyCode, modifiers)

    fun resizeTerminal(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        val current = terminal ?: return
        val replies = current.resize(cols, rows, cellWidth, cellHeight)
        if (replies.isNotEmpty()) session?.sendInput(replies)
        session?.resize(current.geometry.value)
    }

    fun scrollTerminal(rows: Int) = terminal?.scroll(rows)
    fun requestRedraw() = session?.requestRedraw()

    fun forget(host: SavedHost) {
        viewModelScope.launch(Dispatchers.IO) {
            val next = store.forget(host.id)
            stored = next
            _state.value = _state.value.copy(hosts = next.hosts)
        }
    }

    fun repairPairing() {
        val expectedNodeId = _state.value.selectedHost?.nodeId ?: return
        disconnect()
        beginPairing(expectedNodeId = expectedNodeId)
    }

    fun disconnect() {
        session?.close()
        session = null
        terminal?.close()
        terminal = null
        if (_state.value.selectedHost != null) {
            _state.value = _state.value.copy(selectedHost = null, sessionStatus = SessionStatus.Idle)
        }
    }

    override fun onCleared() {
        disconnect()
        super.onCleared()
    }
}

private fun Throwable.safeMessage(): String =
    message?.take(300)?.takeIf(String::isNotBlank) ?: javaClass.simpleName

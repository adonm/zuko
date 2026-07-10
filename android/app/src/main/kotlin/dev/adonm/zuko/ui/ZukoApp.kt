package dev.adonm.zuko.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import android.view.KeyEvent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.adonm.zuko.AppUiState
import dev.adonm.zuko.AppViewModel
import dev.adonm.zuko.core.PairingCode
import dev.adonm.zuko.core.SavedHost
import dev.adonm.zuko.net.SessionStatus
import dev.adonm.zuko.terminal.GhosttyTerminal
import java.text.DateFormat
import java.util.Date
import kotlin.math.floor
import kotlin.math.sign

private val ZukoColors = darkColorScheme(
    primary = Color(0xFFEF7D3C),
    secondary = Color(0xFF75C7B7),
    background = Color(0xFF080B10),
    surface = Color(0xFF111820),
    surfaceVariant = Color(0xFF1B2630),
)

@Composable
fun ZukoApp(model: AppViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    MaterialTheme(colorScheme = ZukoColors) {
        Surface(Modifier.fillMaxSize()) {
            when {
                state.loading -> LoadingScreen()
                state.selectedHost != null && model.terminal != null -> TerminalScreen(model, state)
                else -> HostsScreen(model, state)
            }
            if (state.pairing) PairingDialog(model, state)
        }
    }
}

@Composable
private fun LoadingScreen() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(Modifier.semantics { contentDescription = "Loading secure storage" })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HostsScreen(model: AppViewModel, state: AppUiState) {
    Scaffold(
        topBar = { TopAppBar(title = { Text("Zuko") }) },
        floatingActionButton = {
            FloatingActionButton(onClick = { model.beginPairing() }) { Text("+") }
        },
    ) { padding ->
        if (state.hosts.isEmpty()) {
            Column(
                Modifier.fillMaxSize().padding(padding).padding(28.dp),
                verticalArrangement = Arrangement.Center,
            ) {
                Text("Reach your terminal", style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.height(12.dp))
                Text("On the host, install Zuko and run:")
                Spacer(Modifier.height(12.dp))
                CommandCard("mise use --global github:adonm/zuko && zuko install")
                Spacer(Modifier.height(8.dp))
                CommandCard("zuko share")
                Spacer(Modifier.height(20.dp))
                Button(onClick = { model.beginPairing() }) { Text("Pair a host") }
                state.pairingError?.let { ErrorText(it) }
            }
        } else {
            LazyColumn(
                Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                item { Text("Saved hosts", style = MaterialTheme.typography.titleMedium) }
                items(state.hosts, key = SavedHost::id) { host ->
                    HostCard(host, onOpen = { model.openHost(host) }, onForget = { model.forget(host) })
                }
                item { Spacer(Modifier.height(88.dp)) }
            }
        }
    }
}

@Composable
private fun CommandCard(command: String) {
    val context = LocalContext.current
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Row(Modifier.fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(command, Modifier.weight(1f), fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
            TextButton(onClick = { copy(context, "Zuko command", command) }) { Text("Copy") }
        }
    }
}

@Composable
private fun HostCard(host: SavedHost, onOpen: () -> Unit, onForget: () -> Unit) {
    var confirmForget by remember { mutableStateOf(false) }
    Card(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(host.label, style = MaterialTheme.typography.titleMedium)
                Text(host.nodeId.take(8), color = MaterialTheme.colorScheme.secondary)
                host.lastConnectedAtEpochMillis?.let {
                    Text("Last connected ${DateFormat.getDateTimeInstance().format(Date(it))}", style = MaterialTheme.typography.bodySmall)
                }
            }
            TextButton(onClick = { confirmForget = true }) { Text("Forget") }
        }
    }
    if (confirmForget) {
        AlertDialog(
            onDismissRequest = { confirmForget = false },
            title = { Text("Forget ${host.label}?") },
            text = { Text("This removes local connection data but does not revoke this device on the host.") },
            confirmButton = { TextButton(onClick = { confirmForget = false; onForget() }) { Text("Forget") } },
            dismissButton = { TextButton(onClick = { confirmForget = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun PairingDialog(model: AppViewModel, state: AppUiState) {
    val busy = state.pairingMessage != null
    AlertDialog(
        onDismissRequest = { if (!busy && state.pairingCancelable) model.cancelPairing() },
        title = { Text("Pair a host") },
        text = {
            Column {
                Text("Run `zuko share` on the host, then enter its one-time two-word code.")
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = state.pairingCode,
                    onValueChange = model::updatePairingCode,
                    enabled = !busy,
                    singleLine = true,
                    label = { Text("Pairing code") },
                    isError = state.pairingError != null,
                )
                state.pairingMessage?.let {
                    Row(Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text(it)
                    }
                }
                state.pairingError?.let { ErrorText(it) }
            }
        },
        confirmButton = {
            Button(
                onClick = model::submitPairing,
                enabled = !busy && PairingCode.parse(state.pairingCode) != null,
            ) { Text("Pair") }
        },
        dismissButton = {
            TextButton(onClick = model::cancelPairing, enabled = state.pairingCancelable) {
                Text(if (busy) "Cancel" else "Close")
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TerminalScreen(model: AppViewModel, state: AppUiState) {
    val terminal = model.terminal ?: return
    var ctrl by remember { mutableStateOf(false) }
    var alt by remember { mutableStateOf(false) }
    DisposableEffect(Unit) { onDispose { model.disconnect() } }
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(state.selectedHost?.label.orEmpty())
                        Text(sessionLabel(state.sessionStatus), style = MaterialTheme.typography.labelSmall)
                    }
                },
                navigationIcon = { TextButton(onClick = model::disconnect) { Text("Back") } },
                actions = { TextButton(onClick = model::requestRedraw) { Text("Refresh") } },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            TerminalCanvas(
                terminal = terminal,
                model = model,
                ctrl = ctrl,
                alt = alt,
                onModifiersConsumed = { ctrl = false; alt = false },
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )
            SessionNotice(state.sessionStatus, model)
            ShortcutBar(
                model = model,
                ctrl = ctrl,
                alt = alt,
                onCtrl = { ctrl = !ctrl },
                onAlt = { alt = !alt },
                onModifiersConsumed = { ctrl = false; alt = false },
            )
        }
    }
}

@Composable
private fun TerminalCanvas(
    terminal: GhosttyTerminal,
    model: AppViewModel,
    ctrl: Boolean,
    alt: Boolean,
    onModifiersConsumed: () -> Unit,
    modifier: Modifier,
) {
    val screen by terminal.screen.collectAsStateWithLifecycle()
    val density = LocalDensity.current
    val focusRequester = remember { FocusRequester() }
    var input by remember { mutableStateOf("") }
    var lastWidth by remember { mutableIntStateOf(0) }
    var lastHeight by remember { mutableIntStateOf(0) }
    var drag by remember { mutableFloatStateOf(0f) }
    val fontPx = with(density) { 14.sp.toPx() }
    val paint = remember(fontPx) {
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.rgb(230, 236, 242)
            textSize = fontPx
            typeface = Typeface.MONOSPACE
            isSubpixelText = true
        }
    }
    val cellWidth = remember(paint) { paint.measureText("M").coerceAtLeast(1f) }
    val lineHeight = remember(paint) { (paint.fontMetrics.descent - paint.fontMetrics.ascent).coerceAtLeast(1f) }
    val baseline = remember(paint) { -paint.fontMetrics.ascent }

    Box(
        modifier
            .background(Color(0xFF080B10))
            .clickable { focusRequester.requestFocus() }
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val code = event.nativeKeyEvent.keyCode
                if (code !in SPECIAL_KEYS) return@onPreviewKeyEvent false
                model.sendKey(code, modifiers(ctrl, alt))
                onModifiersConsumed()
                true
            }
            .onSizeChanged { size ->
                if (size.width != lastWidth || size.height != lastHeight) {
                    lastWidth = size.width
                    lastHeight = size.height
                    val cols = floor(size.width / cellWidth).toInt().coerceAtLeast(1)
                    val rows = floor(size.height / lineHeight).toInt().coerceAtLeast(1)
                    model.resizeTerminal(cols, rows, cellWidth.toInt().coerceAtLeast(1), lineHeight.toInt().coerceAtLeast(1))
                }
            }
            .pointerInput(lineHeight) {
                detectVerticalDragGestures(
                    onVerticalDrag = { _, amount ->
                        drag += amount
                        if (kotlin.math.abs(drag) >= lineHeight) {
                            model.scrollTerminal((-drag / lineHeight).toInt())
                            drag %= lineHeight
                        }
                    },
                )
            }
            .semantics { contentDescription = "Remote terminal" },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            drawIntoCanvas { canvas ->
                screen.lineSequence().take(floor(size.height / lineHeight).toInt()).forEachIndexed { row, line ->
                    canvas.nativeCanvas.drawText(line, 0f, baseline + row * lineHeight, paint)
                }
            }
        }
        BasicTextField(
            value = input,
            onValueChange = { value ->
                input = ""
                val normalized = value.replace("\r\n", "\r").replace("\n", "\r")
                if (normalized.isNotEmpty()) {
                    val bytes = if (ctrl && normalized.length == 1 && normalized[0].code in 0x40..0x7f) {
                        byteArrayOf((normalized[0].code and 0x1f).toByte())
                    } else {
                        val raw = normalized.encodeToByteArray()
                        if (alt) byteArrayOf(0x1b) + raw else raw
                    }
                    model.sendInput(bytes)
                    onModifiersConsumed()
                }
            },
            modifier = Modifier.size(2.dp).alpha(0.01f).focusRequester(focusRequester),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.Ascii,
            ),
        )
    }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }
}

@Composable
private fun SessionNotice(status: SessionStatus, model: AppViewModel) {
    AnimatedVisibility(status !is SessionStatus.Connected) {
        val message = sessionLabel(status)
        Row(
            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (status is SessionStatus.Connecting || status is SessionStatus.Reconnecting) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
            }
            Text(message, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
            if (status is SessionStatus.Failed && status.canRePair) {
                TextButton(onClick = model::repairPairing) { Text("Pair again") }
            }
        }
    }
}

@Composable
private fun ShortcutBar(
    model: AppViewModel,
    ctrl: Boolean,
    alt: Boolean,
    onCtrl: () -> Unit,
    onAlt: () -> Unit,
    onModifiersConsumed: () -> Unit,
) {
    val context = LocalContext.current
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).background(MaterialTheme.colorScheme.surface).padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Shortcut("Esc") { model.sendKey(KeyEvent.KEYCODE_ESCAPE, modifiers(ctrl, alt)); onModifiersConsumed() }
        Shortcut("Tab") { model.sendKey(KeyEvent.KEYCODE_TAB, modifiers(ctrl, alt)); onModifiersConsumed() }
        Shortcut("Ctrl", active = ctrl, action = onCtrl)
        Shortcut("Alt", active = alt, action = onAlt)
        Shortcut("←") { model.sendKey(KeyEvent.KEYCODE_DPAD_LEFT, modifiers(ctrl, alt)) }
        Shortcut("↑") { model.sendKey(KeyEvent.KEYCODE_DPAD_UP, modifiers(ctrl, alt)) }
        Shortcut("↓") { model.sendKey(KeyEvent.KEYCODE_DPAD_DOWN, modifiers(ctrl, alt)) }
        Shortcut("→") { model.sendKey(KeyEvent.KEYCODE_DPAD_RIGHT, modifiers(ctrl, alt)) }
        Shortcut("Paste") {
            val clipboard = context.getSystemService(ClipboardManager::class.java)
            val text = clipboard.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
            if (text.isNotEmpty()) model.sendInput(text.replace("\r\n", "\r").replace("\n", "\r").encodeToByteArray())
        }
    }
}

@Composable
private fun Shortcut(label: String, active: Boolean = false, action: () -> Unit) {
    if (active) Button(onClick = action, content = { Text(label) })
    else OutlinedButton(onClick = action, content = { Text(label) })
}

@Composable
private fun ErrorText(message: String) {
    Text(message, Modifier.padding(top = 10.dp), color = MaterialTheme.colorScheme.error)
}

private fun modifiers(ctrl: Boolean, alt: Boolean): Int =
    (if (ctrl) GhosttyTerminal.MOD_CTRL else 0) or (if (alt) GhosttyTerminal.MOD_ALT else 0)

private fun sessionLabel(status: SessionStatus): String = when (status) {
    SessionStatus.Idle -> "Idle"
    SessionStatus.Connecting -> "Connecting…"
    is SessionStatus.Reconnecting -> "Reconnect ${status.attempt} in ${status.delaySeconds}s — ${status.reason}"
    SessionStatus.Connected -> "Connected"
    is SessionStatus.Ended -> status.reason
    is SessionStatus.Failed -> status.reason
}

private fun copy(context: Context, label: String, value: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(label, value))
}

private val SPECIAL_KEYS = setOf(
    KeyEvent.KEYCODE_ESCAPE,
    KeyEvent.KEYCODE_TAB,
    KeyEvent.KEYCODE_ENTER,
    KeyEvent.KEYCODE_DEL,
    KeyEvent.KEYCODE_FORWARD_DEL,
    KeyEvent.KEYCODE_DPAD_LEFT,
    KeyEvent.KEYCODE_DPAD_UP,
    KeyEvent.KEYCODE_DPAD_DOWN,
    KeyEvent.KEYCODE_DPAD_RIGHT,
    KeyEvent.KEYCODE_MOVE_HOME,
    KeyEvent.KEYCODE_MOVE_END,
    KeyEvent.KEYCODE_PAGE_UP,
    KeyEvent.KEYCODE_PAGE_DOWN,
)

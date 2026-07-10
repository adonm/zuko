package dev.adonm.zuko

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import dev.adonm.zuko.core.PairingCode
import dev.adonm.zuko.ui.ZukoApp

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        consumePairingIntent(intent)
        setContent { ZukoApp(model) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumePairingIntent(intent)
    }

    private fun consumePairingIntent(intent: Intent?) {
        val value = intent?.dataString ?: return
        PairingCode.parse(value)?.let(model::beginPairing)
    }
}

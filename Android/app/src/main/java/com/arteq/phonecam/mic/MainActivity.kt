package com.arteq.phonecam.mic

import android.Manifest
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlin.math.pow

/** One big button: connect, then tap to dictate on the Mac. Settings live behind the gear. */
class MainActivity : ComponentActivity() {
    companion object {
        val PERMISSIONS = arrayOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.POST_NOTIFICATIONS,
        )

        fun hasPermissions(context: Context) =
            PERMISSIONS.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent { AppTheme { MicScreen() } }
    }
}

private enum class Mode { OFF, SEARCHING, CONNECTING, READY, LISTENING }

/** What the screen shows, read from the service several times a second. */
private data class MicState(
    val mode: Mode = Mode.OFF,
    val macName: String? = null,
    val detail: String = "",
    val level: Float = 0f,
    val stats: String = "",
    val savedMac: Boolean = false,
    val backgroundAllowed: Boolean = true,
)

private fun readState(context: Context): MicState {
    val service = MicService.instance
    val backgroundAllowed = context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)
    val savedMac = MicService.prefs(context).contains("macAddress")
    if (service == null) return MicState(savedMac = savedMac, backgroundAllowed = backgroundAllowed)
    return MicState(
        mode = when (service.phase) {
            MicService.Phase.SEARCHING -> Mode.SEARCHING
            MicService.Phase.CONNECTING -> Mode.CONNECTING
            MicService.Phase.CONNECTED -> if (service.macListening) Mode.LISTENING else Mode.READY
        },
        macName = service.macName,
        detail = service.detail,
        level = meterLevel(service.levelDb),
        stats = "${service.packetsSent} packets sent, ${service.packetsDropped} dropped" +
            if (service.rttMillis >= 0) ", ${service.rttMillis} ms round trip" else "",
        savedMac = savedMac,
        backgroundAllowed = backgroundAllowed,
    )
}

/**
 * 0–1 for the meter. The noise suppressor takes silence down to about -110 dBFS, so the meter can
 * start at -55; normal speech (about -45 to -25 dBFS with the call-style source) fills most of it.
 */
private fun meterLevel(db: Double): Float = ((db + 55) / 30).toFloat().coerceIn(0f, 1f).pow(0.9f)

@Composable
private fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MicScreen() {
    val context = LocalContext.current
    var state by remember { mutableStateOf(readState(context)) }
    val history = remember { mutableStateListOf<Float>().apply { repeat(48) { add(0f) } } }
    LaunchedEffect(Unit) {
        var smoothed = 0f
        while (true) {
            val read = readState(context)
            val live = if (read.mode == Mode.READY || read.mode == Mode.LISTENING) read.level else 0f
            // Rise quickly with the voice, fall back slowly, so it doesn't flicker on every syllable.
            smoothed += (live - smoothed) * if (live > smoothed) 0.5f else 0.15f
            state = read.copy(level = smoothed)
            history.removeAt(0)
            history.add(smoothed)
            delay(60)
        }
    }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (MainActivity.hasPermissions(context)) MicService.start(context)
    }
    fun turnOn() {
        if (MainActivity.hasPermissions(context)) MicService.start(context) else permissions.launch(MainActivity.PERMISSIONS)
    }
    var showSettings by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { StatusChip(state) },
                actions = {
                    IconButton(onClick = { showSettings = true }) {
                        Icon(painterResource(R.drawable.ic_settings), contentDescription = "Settings")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = Color.Transparent),
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.weight(1f))
            BigButton(state, onTurnOn = ::turnOn)
            Spacer(Modifier.height(36.dp))
            Labels(state)
            Spacer(Modifier.height(28.dp))
            Waveform(history, listening = state.mode == Mode.LISTENING, visible = state.mode == Mode.READY || state.mode == Mode.LISTENING)
            Spacer(Modifier.weight(1f))
            AnimatedVisibility(state.mode != Mode.OFF, enter = fadeIn(), exit = fadeOut()) {
                OutlinedButton(onClick = { MicService.stop(context) }, modifier = Modifier.padding(bottom = 16.dp)) {
                    Icon(painterResource(R.drawable.ic_power), contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Turn off")
                }
            }
        }
    }
    if (showSettings) SettingsSheet(state) { showSettings = false }
}

@Composable
private fun StatusChip(state: MicState) {
    val connected = state.mode == Mode.READY || state.mode == Mode.LISTENING
    val dot by animateColorAsState(
        when (state.mode) {
            Mode.OFF -> MaterialTheme.colorScheme.outline
            Mode.SEARCHING, Mode.CONNECTING -> Color(0xFFF9A825)
            Mode.READY, Mode.LISTENING -> Color(0xFF34A853)
        }, label = "dot")
    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
            Spacer(Modifier.size(8.dp))
            Icon(painterResource(R.drawable.ic_laptop), contentDescription = null, modifier = Modifier.size(18.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.size(6.dp))
            Text(
                if (connected) state.macName ?: "Mac" else if (state.mode == Mode.OFF) "Not connected" else "Connecting",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Off: tap to connect. Connected: tap (or hold) to dictate; it presses Right Option on the Mac. */
@Composable
private fun BigButton(state: MicState, onTurnOn: () -> Unit) {
    val view = LocalView.current
    var pressed by remember { mutableStateOf(false) }
    val scheme = MaterialTheme.colorScheme
    val container by animateColorAsState(
        when (state.mode) {
            Mode.OFF -> scheme.surfaceContainerHighest
            Mode.SEARCHING, Mode.CONNECTING -> scheme.secondaryContainer
            Mode.READY -> scheme.primary
            Mode.LISTENING -> scheme.error
        }, label = "button")
    val content = when (state.mode) {
        Mode.OFF -> scheme.onSurfaceVariant
        Mode.SEARCHING, Mode.CONNECTING -> scheme.onSecondaryContainer
        Mode.READY -> scheme.onPrimary
        Mode.LISTENING -> scheme.onError
    }
    val scale by animateFloatAsState(if (pressed) 0.92f else 1f, label = "press")
    val level by animateFloatAsState(state.level, tween(90), label = "level")
    val pulse = rememberInfiniteTransition(label = "pulse")
    val ripple by pulse.animateFloat(0f, 1f, infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Restart), label = "ripple")
    val ringColor = container

    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(320.dp)) {
        Canvas(Modifier.fillMaxSize()) {
            val base = 112.dp.toPx()
            when (state.mode) {
                // Rings that follow the voice while the Mac can hear it.
                Mode.READY, Mode.LISTENING -> {
                    drawCircle(ringColor.copy(alpha = 0.16f), radius = base * (1.08f + 0.24f * level))
                    drawCircle(ringColor.copy(alpha = 0.10f), radius = base * (1.16f + 0.42f * level))
                }
                // An expanding ring while it looks for the Mac.
                Mode.SEARCHING, Mode.CONNECTING ->
                    drawCircle(ringColor.copy(alpha = 0.5f * (1 - ripple)), radius = base * (1f + 0.4f * ripple))
                Mode.OFF -> {}
            }
        }
        Surface(
            shape = CircleShape,
            color = container,
            shadowElevation = if (state.mode == Mode.OFF) 0.dp else 6.dp,
            modifier = Modifier
                .size(224.dp)
                .scale(scale)
                .semantics {
                    role = Role.Button
                    contentDescription = when (state.mode) {
                        Mode.OFF -> "Connect to the Mac"
                        Mode.READY -> "Start dictation"
                        Mode.LISTENING -> "Stop dictation"
                        else -> "Connecting"
                    }
                }
                .pointerInput(state.mode) {
                    when (state.mode) {
                        Mode.OFF -> detectTapGestures(onPress = {
                            pressed = true
                            val released = tryAwaitRelease()
                            pressed = false
                            if (released) {
                                view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                                onTurnOn()
                            }
                        })
                        // Down and up go to the Mac as they happen, so a tap toggles FluidVoice and a
                        // hold works for push-to-talk shortcuts too.
                        Mode.READY, Mode.LISTENING -> detectTapGestures(onPress = {
                            pressed = true
                            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                            MicService.instance?.talk(true)
                            tryAwaitRelease()
                            MicService.instance?.talk(false)
                            pressed = false
                        })
                        else -> {}
                    }
                },
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    painterResource(if (state.mode == Mode.OFF) R.drawable.ic_power else R.drawable.ic_mic),
                    contentDescription = null,
                    tint = content,
                    modifier = Modifier.size(84.dp),
                )
            }
        }
    }
}

@Composable
private fun Labels(state: MicState) {
    val (title, subtitle) = when (state.mode) {
        Mode.OFF -> "Mic off" to "Tap to connect to your Mac"
        Mode.SEARCHING -> "Looking for your Mac" to
            state.detail.ifEmpty { "PhoneCam needs to be running with Bluetooth on" }
        Mode.CONNECTING -> "Connecting" to (state.macName ?: "your Mac")
        Mode.READY -> "Tap to dictate" to "Your voice goes to PhoneCam Microphone"
        Mode.LISTENING -> "Listening" to "Tap to stop"
    }
    AnimatedContent(title to subtitle, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "labels") { (t, s) ->
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(t, style = MaterialTheme.typography.headlineMedium, textAlign = TextAlign.Center)
            Spacer(Modifier.height(6.dp))
            Text(s, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center)
        }
    }
}

/** The last few seconds of mic level, as bars. */
@Composable
private fun Waveform(history: List<Float>, listening: Boolean, visible: Boolean) {
    val color by animateColorAsState(
        if (listening) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary, label = "wave")
    val alpha by animateFloatAsState(if (visible) 1f else 0f, label = "waveAlpha")
    Canvas(Modifier.fillMaxWidth().height(56.dp)) {
        val bar = size.width / history.size
        val width = bar * 0.55f
        history.forEachIndexed { index, level ->
            val height = (4.dp.toPx()).coerceAtLeast(size.height * level)
            drawRoundRect(
                color = color.copy(alpha = alpha * (0.35f + 0.65f * index / history.size)),
                topLeft = Offset(index * bar + (bar - width) / 2, (size.height - height) / 2),
                size = Size(width, height),
                cornerRadius = CornerRadius(width / 2),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsSheet(state: MicState, onDismiss: () -> Unit) {
    val context = LocalContext.current
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.navigationBarsPadding().padding(bottom = 32.dp)) {
            Text("Settings", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp))
            SettingRow("Quick Settings tile", "Turn the mic on or off from anywhere", "Add") { addTile(context) }
            SettingRow(
                "Run in the background",
                if (state.backgroundAllowed) "Allowed: battery saving won't stop the mic" else "Keeps battery saving from stopping the mic",
                if (state.backgroundAllowed) null else "Allow",
            ) {
                context.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${context.packageName}")))
            }
            if (state.savedMac) {
                SettingRow("Paired Mac", "Connects to this Mac first", if (state.mode == Mode.OFF) "Forget" else null) {
                    MicService.prefs(context).edit().remove("macAddress").apply()
                }
            }
            if (state.mode != Mode.OFF) {
                ListItem(headlineContent = { Text("Connection") }, supportingContent = { Text(state.stats) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                    modifier = Modifier.padding(horizontal = 8.dp))
            }
            Text(
                "PhoneCam Mic ${BuildConfigVersion.name(context)} · needs PhoneCam on the Mac with “Also over Bluetooth” on",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun SettingRow(title: String, summary: String, action: String?, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(summary) },
        trailingContent = action?.let { { TextButton(onClick = onClick) { Text(it) } } },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.padding(horizontal = 8.dp),
    )
}

private object BuildConfigVersion {
    fun name(context: Context): String =
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
}

private fun addTile(context: Context) {
    if (Build.VERSION.SDK_INT >= 33) {
        context.getSystemService(StatusBarManager::class.java).requestAddTileService(
            ComponentName(context, MicTileService::class.java), "PhoneCam Mic",
            Icon.createWithResource(context, R.drawable.ic_mic), context.mainExecutor) {}
    } else {
        context.startActivity(Intent(Settings.ACTION_SETTINGS))
    }
}

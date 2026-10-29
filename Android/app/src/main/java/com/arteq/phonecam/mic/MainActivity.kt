package com.arteq.phonecam.mic

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/** Turns the mic on and off, holds the Talk button and shows how the link is doing. */
class MainActivity : Activity() {
    companion object {
        private val PERMISSIONS = arrayOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.POST_NOTIFICATIONS,
        )

        fun hasPermissions(context: Context) =
            PERMISSIONS.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var detail: TextView
    private lateinit var level: ProgressBar
    private lateinit var power: Button
    private lateinit var talk: Button
    private lateinit var stats: TextView
    private lateinit var battery: Button
    private lateinit var tile: Button
    private lateinit var forget: Button

    private val dp get() = resources.displayMetrics.density

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (20 * dp).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
            fitsSystemWindows = true
        }
        status = TextView(this).apply { textSize = 24f; setTypeface(typeface, Typeface.BOLD) }
        detail = TextView(this).apply { textSize = 15f; alpha = 0.7f; setPadding(0, (4 * dp).toInt(), 0, (12 * dp).toInt()) }
        level = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 60 }
        power = Button(this).apply { setOnClickListener { togglePower() } }
        talk = Button(this).apply {
            text = "TALK"
            textSize = 34f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setOnTouchListener { view, event ->
                val service = MicService.instance ?: return@setOnTouchListener true
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        service.talk(true)
                        view.setBackgroundColor(Color.parseColor("#C62828"))
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        service.talk(false)
                        view.setBackgroundColor(Color.parseColor("#2E7D32"))
                    }
                }
                true
            }
        }
        stats = TextView(this).apply { textSize = 12f; typeface = Typeface.MONOSPACE; alpha = 0.6f }
        val hint = TextView(this).apply {
            textSize = 13f
            alpha = 0.7f
            text = "TALK presses Right Option on the Mac: tap to start dictating in FluidVoice, tap again to stop."
            setPadding(0, (8 * dp).toInt(), 0, 0)
        }
        battery = Button(this).apply {
            text = "Allow running in the background"
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
            }
        }
        tile = Button(this).apply {
            text = "Add the Quick Settings tile"
            setOnClickListener { addTile() }
        }
        forget = Button(this).apply {
            text = "Forget this Mac"
            setOnClickListener {
                MicService.prefs(this@MainActivity).edit().remove("macAddress").apply()
                refresh()
            }
        }

        root.addView(status)
        root.addView(detail)
        root.addView(level)
        root.addView(power)
        root.addView(talk, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (200 * dp).toInt()).apply {
            topMargin = (12 * dp).toInt()
        })
        root.addView(hint)
        root.addView(View(this), LinearLayout.LayoutParams(0, 0, 1f))
        root.addView(stats)
        root.addView(battery)
        root.addView(tile)
        root.addView(forget)
        setContentView(root)

        if (!hasPermissions(this)) requestPermissions(PERMISSIONS, 1)
    }

    override fun onResume() {
        super.onResume()
        main.post(object : Runnable {
            override fun run() {
                refresh()
                main.postDelayed(this, 500)
            }
        })
    }

    override fun onPause() {
        main.removeCallbacksAndMessages(null)
        super.onPause()
    }

    private fun togglePower() {
        if (MicService.instance != null) {
            MicService.stop(this)
        } else if (!hasPermissions(this)) {
            requestPermissions(PERMISSIONS, 1)
        } else {
            MicService.start(this)
        }
        main.postDelayed({ refresh() }, 300)
    }

    private fun addTile() {
        if (Build.VERSION.SDK_INT >= 33) {
            getSystemService(StatusBarManager::class.java).requestAddTileService(
                ComponentName(this, MicTileService::class.java), "PhoneCam Mic",
                Icon.createWithResource(this, R.drawable.ic_mic), mainExecutor) { refresh() }
        } else {
            detail.text = "Edit Quick Settings and drag the PhoneCam Mic tile in."
        }
    }

    private fun refresh() {
        val service = MicService.instance
        val connected = service?.phase == MicService.Phase.CONNECTED
        power.text = if (service == null) "Turn mic on" else "Turn mic off"
        talk.isEnabled = connected
        talk.setBackgroundColor(Color.parseColor(if (connected) "#2E7D32" else "#9E9E9E"))
        if (service == null) {
            status.text = "Mic off"
            detail.text = MicService.prefs(this).getString("macAddress", null)
                ?.let { "Turn it on to send this phone's mic to PhoneCam on your Mac." }
                ?: "Turn on “Also over Bluetooth” in PhoneCam on the Mac, then turn the mic on here."
            level.progress = 0
            stats.text = ""
        } else {
            status.text = service.statusText()
            detail.text = when {
                connected && service.macListening -> "An app on the Mac is listening."
                connected -> "Ready. Nothing on the Mac is listening yet."
                service.detail.isNotEmpty() -> service.detail
                else -> "Make sure PhoneCam is running on the Mac with Bluetooth on."
            }
            level.progress = (service.levelDb + 60).toInt().coerceIn(0, 60)
            stats.text = "Sent ${service.packetsSent} · dropped ${service.packetsDropped}" +
                if (service.rttMillis >= 0) " · ${service.rttMillis} ms" else ""
        }
        val ignoring = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        battery.visibility = if (ignoring) View.GONE else View.VISIBLE
        forget.visibility = if (MicService.prefs(this).contains("macAddress") && service == null) View.VISIBLE else View.GONE
    }
}

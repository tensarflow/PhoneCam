package com.arteq.btmicspike

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView

/** Start/stop, a Talk button (sends Right Option to the Mac) and live link stats. */
class MainActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var stats: TextView
    private lateinit var encrypted: CheckBox
    private lateinit var startStop: Button
    private var lastSent = 0
    private var lastBytes = 0L
    private var bundle = 3
    private var bitrate = 32000

    private val permissions = arrayOf(
        Manifest.permission.RECORD_AUDIO,
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.POST_NOTIFICATIONS,
    )

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val padding = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
            fitsSystemWindows = true
        }
        status = TextView(this).apply { textSize = 20f; setTypeface(typeface, Typeface.BOLD) }
        stats = TextView(this).apply { textSize = 13f; typeface = Typeface.MONOSPACE }
        encrypted = CheckBox(this).apply { text = "Encrypted link (pairing)"; isChecked = true }
        startStop = Button(this).apply { setOnClickListener { toggle() } }
        val talk = Button(this).apply {
            text = "TALK"
            textSize = 32f
            setBackgroundColor(Color.parseColor("#2E7D32"))
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setOnTouchListener { view, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        StreamService.instance?.talk(true)
                        view.setBackgroundColor(Color.parseColor("#C62828"))
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        StreamService.instance?.talk(false)
                        view.setBackgroundColor(Color.parseColor("#2E7D32"))
                    }
                }
                true
            }
        }
        root.addView(status)
        root.addView(encrypted)
        root.addView(startStop)
        root.addView(stats, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(talk, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (180 * resources.displayMetrics.density).toInt()))
        setContentView(root)

        val missing = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 1)
        handleAutostart(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAutostart(intent)
    }

    /**
     * `adb shell am start -n com.arteq.btmicspike/.MainActivity --ez start true [--ei bundle 3] [--ei bitrate 32000]`
     * starts streaming.
     */
    private fun handleAutostart(intent: Intent?) {
        if (intent?.hasExtra("encrypted") == true) encrypted.isChecked = intent.getBooleanExtra("encrypted", true)
        bundle = intent?.getIntExtra("bundle", bundle) ?: bundle
        bitrate = intent?.getIntExtra("bitrate", bitrate) ?: bitrate
        if (intent?.getBooleanExtra("start", false) == true && StreamService.instance == null) toggle()
    }

    override fun onResume() {
        super.onResume()
        main.post(object : Runnable {
            override fun run() {
                refresh()
                main.postDelayed(this, 1000)
            }
        })
    }

    override fun onPause() {
        main.removeCallbacksAndMessages(null)
        super.onPause()
    }

    private fun toggle() {
        val service = StreamService.instance
        if (service == null) {
            startForegroundService(Intent(this, StreamService::class.java)
                .putExtra(StreamService.EXTRA_ENCRYPTED, encrypted.isChecked)
                .putExtra("bundle", bundle)
                .putExtra("bitrate", bitrate))
        } else {
            startService(Intent(this, StreamService::class.java).setAction(StreamService.ACTION_STOP))
        }
        main.postDelayed({ refresh() }, 300)
    }

    private fun refresh() {
        val s = StreamService.instance
        startStop.text = if (s == null) "Start streaming" else "Stop"
        encrypted.isEnabled = s == null
        if (s == null) {
            status.text = "Stopped"
            stats.text = ""
            return
        }
        status.text = s.state
        val now = SystemClock.elapsedRealtime()
        val running = (now - s.startedAt) / 1000
        val connected = if (s.connectedAt > 0) (now - s.connectedAt) / 1000 else 0
        val kbps = (s.bytesSent - lastBytes) * 8 / 1000.0
        val perSecond = s.packetsSent - lastSent
        lastSent = s.packetsSent
        lastBytes = s.bytesSent
        val battery = s.battery()
        stats.text = """
            Running:     ${running / 60}m ${running % 60}s
            Connected:   ${connected / 60}m ${connected % 60}s   reconnects: ${s.reconnects}
            Link:        ${if (s.encrypted) "encrypted" else "plain"}, PHY ${s.phy}
            Opus:        ${s.bitrate / 1000} kbit/s, ${s.bundle} packets per write (${s.writes} writes)
            Encoded:     ${s.packetsEncoded}
            Sent:        ${s.packetsSent} ($perSecond/s, ${"%.1f".format(kbps)} kbit/s)
            Dropped:     ${s.queueDrops} (link behind)   ${s.notConnectedDrops} (not connected)
            Max write:   ${s.maxWriteMillis} ms
            Mic level:   ${"%.0f".format(s.levelDb)} dBFS
            Battery:     $battery% (started ${s.batteryStart}%), ${s.currentMilliamps()} mA
        """.trimIndent()
    }
}

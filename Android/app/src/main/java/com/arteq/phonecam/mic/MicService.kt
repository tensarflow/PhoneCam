package com.arteq.phonecam.mic

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.os.PowerManager
import android.os.SystemClock
import android.service.quicksettings.TileService
import android.util.Log
import java.io.DataInputStream
import java.io.IOException
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

private const val TAG = "PhoneCamMic"

/**
 * Streams the microphone to PhoneCam on the Mac over Bluetooth LE while it runs.
 *
 * PhoneCam advertises a service whose characteristic holds the PSM of an encrypted L2CAP channel.
 * We find it, read the PSM (Android pairs the first time) and open the channel. Audio is 20 ms Opus
 * packets, three per write: the link carries a limited number of writes per second.
 */
@SuppressLint("MissingPermission")
class MicService : Service() {
    companion object {
        @Volatile var instance: MicService? = null
            private set

        const val ACTION_STOP = "stop"
        const val ACTION_TALK = "talk"
        private const val SAMPLE_RATE = 48000
        private const val FRAME = 960 // 20 ms
        private const val BITRATE = 32000
        private const val PACKETS_PER_WRITE = 3
        private const val QUEUE_LIMIT = 25 // 500 ms
        // Flow control: stop sending when the Mac is this many packets behind, resume below RESUME.
        private const val BACKLOG_LIMIT = 25
        private const val BACKLOG_RESUME = 10
        private const val GIVE_UP_MILLIS = 60_000L
        private const val NOTIFICATION = 1
        private const val NOTICE = 2

        fun start(context: Context) = context.startForegroundService(Intent(context, MicService::class.java))

        fun stop(context: Context) = context.startService(Intent(context, MicService::class.java).setAction(ACTION_STOP))

        fun prefs(context: Context) = context.getSharedPreferences("mic", Context.MODE_PRIVATE)
    }

    enum class Phase { SEARCHING, CONNECTING, CONNECTED }

    // Read by the screen and the notification.
    @Volatile var phase = Phase.SEARCHING
        private set
    @Volatile var macName: String? = null
        private set
    /** An app on the Mac is recording from PhoneCam Microphone. */
    @Volatile var macListening = false
        private set
    @Volatile var levelDb = -90.0
        private set
    @Volatile var rttMillis = -1L
        private set
    @Volatile var packetsSent = 0
        private set
    @Volatile var packetsDropped = 0
        private set
    @Volatile var detail = ""
        private set

    private val main = Handler(Looper.getMainLooper())
    private lateinit var bluetooth: BluetoothManager
    private var gatt: BluetoothGatt? = null
    @Volatile private var socket: BluetoothSocket? = null
    private val queue = LinkedBlockingDeque<ByteArray>()
    @Volatile private var running = false
    private var audioThread: Thread? = null
    private var senderThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var scanning = false
    private var scanStartedAt = 0L
    private var searchingSince = 0L
    private var sequence = 0
    @Volatile private var ackedSequence = -1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP, ACTION_TALK -> {
                if (!running) stopSelf()
                else if (intent.action == ACTION_STOP) shutdown(null)
                else tapTalk()
                return START_NOT_STICKY
            }
        }
        if (running) return START_NOT_STICKY
        startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        instance = this
        running = true
        bluetooth = getSystemService(BluetoothManager::class.java)
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "phonecammic:stream").apply { acquire(12 * 60 * 60 * 1000L) }
        audioThread = Thread(::audioLoop, "audio").apply { start() }
        senderThread = Thread(::sendLoop, "sender").apply { start() }
        searchingSince = SystemClock.elapsedRealtime()
        scan()
        main.postDelayed(pinger, 1000)
        updateTile()
        log("started")
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        shutdown(null)
        super.onDestroy()
    }

    /** Stops everything; [notice] is shown afterwards to explain why, if it wasn't the user. */
    private fun shutdown(notice: String?) {
        main.post {
            if (!running) return@post
            running = false
            main.removeCallbacksAndMessages(null)
            stopScan()
            closeLink()
            audioThread?.interrupt()
            senderThread?.interrupt()
            wakeLock?.takeIf { it.isHeld }?.release()
            instance = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            if (notice != null) showNotice(notice)
            updateTile()
            stopSelf()
            log("stopped${notice?.let { ": $it" } ?: ""}")
        }
    }

    // MARK: Talk

    fun talk(down: Boolean) {
        if (socket == null) return
        queue.offerFirst(Protocol.frame(if (down) Protocol.TALK_DOWN else Protocol.TALK_UP))
    }

    /** A press and release, as from the notification's Talk button. */
    fun tapTalk() {
        talk(true)
        main.postDelayed({ talk(false) }, 80)
    }

    // MARK: Finding and connecting to the Mac

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!scanning) return
            // Prefer the Mac we used last; take another one only if that one doesn't show up.
            val saved = prefs(this@MicService).getString("macAddress", null)
            val waited = SystemClock.elapsedRealtime() - scanStartedAt > 4000
            if (saved != null && result.device.address != saved && !waited) return
            stopScan()
            log("found ${result.device.address} (${result.scanRecord?.deviceName}) rssi ${result.rssi}")
            result.scanRecord?.deviceName?.let { macName = it }
            connect(result.device)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            retry("Bluetooth scan failed ($errorCode)")
        }
    }

    private fun scan() {
        if (!running || scanning || gatt != null) return
        val scanner = bluetooth.adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner
        if (scanner == null) {
            retry("Bluetooth is off")
            return
        }
        setPhase(Phase.SEARCHING, "")
        scanning = true
        scanStartedAt = SystemClock.elapsedRealtime()
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(Protocol.SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    private fun stopScan() {
        if (!scanning) return
        scanning = false
        try { bluetooth.adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: IllegalStateException) {}
    }

    private fun connect(device: BluetoothDevice) {
        setPhase(Phase.CONNECTING, "")
        gatt = device.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                g.setPreferredPhy(BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK,
                    BluetoothDevice.PHY_OPTION_NO_PREFERRED)
                main.postDelayed({ if (gatt === g) g.discoverServices() }, 300)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                main.post { if (gatt === g) linkLost("disconnected ($status)") }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val characteristic = g.getService(Protocol.SERVICE)?.getCharacteristic(Protocol.PSM_CHARACTERISTIC)
            if (characteristic == null) {
                main.post { linkLost("PhoneCam isn't offering the mic") }
                return
            }
            // Reading it needs encryption: the first time, Android asks to pair here.
            g.readCharacteristic(characteristic)
        }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            psmRead(g, value, status)
        }

        @Deprecated("Called before Android 13")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT < 33) @Suppress("DEPRECATION") psmRead(g, c.value ?: ByteArray(0), status)
        }
    }

    private fun psmRead(g: BluetoothGatt, value: ByteArray, status: Int) {
        if (status != BluetoothGatt.GATT_SUCCESS || value.size < 2) {
            // Status 133 while the pairing prompt is up; the retry after pairing works.
            main.post { linkLost("couldn't read the channel ($status)") }
            return
        }
        val psm = (value[0].toInt() and 0xff) or ((value[1].toInt() and 0xff) shl 8)
        Thread({ openChannel(g.device, psm) }, "l2cap-open").start()
    }

    private fun openChannel(device: BluetoothDevice, psm: Int) {
        try {
            val s = device.createL2capChannel(psm)
            s.connect()
            queue.clear()
            ackedSequence = -1
            socket = s
            prefs(this).edit().putString("macAddress", device.address).apply()
            val name = "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}".toByteArray()
            queue.offerFirst(Protocol.frame(Protocol.HELLO, byteArrayOf(Protocol.VERSION.toByte()) + name))
            Thread({ readLoop(s) }, "reader").start()
            main.post { setPhase(Phase.CONNECTED, "") }
            log("connected to ${device.address}")
        } catch (e: IOException) {
            main.post { linkLost("channel: ${e.message}") }
        }
    }

    private fun readLoop(s: BluetoothSocket) {
        try {
            val input = DataInputStream(s.inputStream)
            while (running && socket === s) {
                val type = input.readUnsignedByte()
                val payload = ByteArray(input.readUnsignedShort())
                input.readFully(payload)
                handle(type, payload)
            }
        } catch (e: IOException) {
            main.post { if (socket === s) linkLost("read: ${e.message}") }
        }
    }

    private fun handle(type: Int, payload: ByteArray) {
        when (type) {
            Protocol.WELCOME -> {
                macName = String(payload, 1, payload.size - 1)
                main.post { updateNotification() }
            }
            Protocol.STATUS -> {
                macListening = payload.isNotEmpty() && payload[0].toInt() and 1 != 0
                main.post { updateNotification() }
            }
            Protocol.ACK -> if (payload.size >= 2) {
                ackedSequence = ((payload[0].toInt() and 0xff) shl 8) or (payload[1].toInt() and 0xff)
            }
            Protocol.PING -> queue.offerFirst(Protocol.frame(Protocol.PONG, payload))
            Protocol.PONG -> if (payload.size == 8) rttMillis = SystemClock.elapsedRealtime() - Protocol.readLong(payload)
            Protocol.DISARM -> {
                val reason = payload.firstOrNull()?.toInt() ?: 0
                log("Mac turned the mic off ($reason)")
                shutdown(if (reason == Protocol.DISARM_IDLE) "Turned off: not used for 10 minutes" else "Turned off on the Mac")
            }
        }
    }

    private val pinger = object : Runnable {
        override fun run() {
            if (socket != null) queue.offerFirst(Protocol.frame(Protocol.PING, Protocol.long(SystemClock.elapsedRealtime())))
            main.postDelayed(this, 1000)
        }
    }

    private fun linkLost(reason: String) {
        if (!running) return
        log("link lost: $reason")
        val wasConnected = socket != null
        closeLink()
        if (wasConnected) searchingSince = SystemClock.elapsedRealtime()
        retry(reason)
    }

    private fun retry(reason: String) {
        if (!running) return
        if (SystemClock.elapsedRealtime() - searchingSince > GIVE_UP_MILLIS) {
            shutdown("Turned off: couldn't reach the Mac. Is PhoneCam running with Bluetooth on?")
            return
        }
        setPhase(Phase.SEARCHING, reason)
        main.postDelayed({ if (running && socket == null && gatt == null) scan() }, 2000)
    }

    private fun closeLink() {
        val s = socket
        socket = null
        try { s?.close() } catch (_: IOException) {}
        gatt?.let {
            it.disconnect()
            it.close()
        }
        gatt = null
        macListening = false
        rttMillis = -1
    }

    private fun setPhase(newPhase: Phase, newDetail: String) {
        val changed = phase != newPhase
        phase = newPhase
        detail = newDetail
        if (changed) updateNotification()
    }

    // MARK: Sending

    private fun sendLoop() {
        val pending = ArrayList<ByteArray>()
        var pendingSocket: BluetoothSocket? = null
        var lastWritten = -1
        var congested = false
        while (running) {
            val frame = try { queue.poll(1, TimeUnit.SECONDS) } catch (_: InterruptedException) { return } ?: continue
            val s = socket ?: continue
            if (s !== pendingSocket) {
                // Audio bundled for a previous connection is stale.
                pending.clear()
                pendingSocket = s
                lastWritten = -1
                congested = false
            }
            val isAudio = frame[0].toInt() == Protocol.AUDIO
            if (isAudio) {
                pending.add(frame)
                if (pending.size < PACKETS_PER_WRITE) continue
                // Android buffers writes without limit, so watch the Mac's acks: if it falls behind,
                // drop audio rather than let the delay grow.
                val acked = ackedSequence
                val backlog = if (acked < 0 || lastWritten < 0) 0 else (lastWritten - acked + 65536) % 65536
                congested = if (congested) backlog > BACKLOG_RESUME else backlog > BACKLOG_LIMIT
                if (congested) {
                    packetsDropped += pending.size
                    pending.clear()
                    continue
                }
            }
            val data = if (isAudio) pending.reduce { a, b -> a + b } else frame
            try {
                s.outputStream.write(data)
                if (isAudio) {
                    val last = pending.last()
                    lastWritten = ((last[3].toInt() and 0xff) shl 8) or (last[4].toInt() and 0xff)
                    packetsSent += pending.size
                    pending.clear()
                }
            } catch (e: IOException) {
                pending.clear()
                main.post { if (socket === s) linkLost("write: ${e.message}") }
            }
        }
    }

    // MARK: Audio

    private fun audioLoop() {
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        // VOICE_COMMUNICATION runs the phone's echo canceller, which removes whatever the phone itself
        // plays (notifications, media) from the mic. VOICE_RECOGNITION doesn't, so that leaked in.
        val recorder = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, max(minBuffer, FRAME * 2 * 8))
        // Most phones turn these on with that source anyway; ask explicitly where they're offered.
        val effects = listOfNotNull(
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(recorder.audioSessionId) else null,
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(recorder.audioSessionId) else null,
        ).onEach { it.enabled = true }
        log("audio effects: ${effects.joinToString { it.descriptor.name }}")
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, SAMPLE_RATE, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, FRAME * 2)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()
        recorder.startRecording()
        val pcm = ByteArray(FRAME * 2)
        val info = MediaCodec.BufferInfo()
        var presentationUs = 0L
        try {
            while (running) {
                var filled = 0
                while (filled < pcm.size && running) {
                    val read = recorder.read(pcm, filled, pcm.size - filled)
                    if (read < 0) throw IOException("AudioRecord.read $read")
                    filled += read
                }
                val captureMillis = SystemClock.elapsedRealtime()
                levelDb = level(pcm)
                val input = encoder.dequeueInputBuffer(20_000)
                if (input >= 0) {
                    encoder.getInputBuffer(input)!!.apply { clear(); put(pcm, 0, filled) }
                    encoder.queueInputBuffer(input, 0, filled, presentationUs, 0)
                    presentationUs += 20_000
                }
                while (true) {
                    val output = encoder.dequeueOutputBuffer(info, 0)
                    if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) continue
                    if (output < 0) break
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                        val packet = ByteArray(info.size)
                        encoder.getOutputBuffer(output)!!.apply { position(info.offset); get(packet) }
                        enqueue(packet, captureMillis)
                    }
                    encoder.releaseOutputBuffer(output, false)
                }
            }
        } catch (e: Exception) {
            if (running) {
                log("audio stopped: $e")
                shutdown("Turned off: the microphone stopped (${e.message})")
            }
        } finally {
            effects.forEach { it.release() }
            recorder.stop()
            recorder.release()
            encoder.stop()
            encoder.release()
        }
    }

    private fun enqueue(packet: ByteArray, captureMillis: Long) {
        val frame = Protocol.audio(sequence, captureMillis, packet)
        sequence = (sequence + 1) and 0xffff
        if (socket == null) return
        while (queue.size >= QUEUE_LIMIT) {
            val oldest = queue.firstOrNull { it[0].toInt() == Protocol.AUDIO } ?: break
            if (queue.removeFirstOccurrence(oldest)) packetsDropped++
        }
        queue.offerLast(frame)
    }

    private fun level(pcm: ByteArray): Double {
        var sum = 0.0
        for (i in 0 until pcm.size / 2) {
            val sample = ((pcm[2 * i + 1].toInt() shl 8) or (pcm[2 * i].toInt() and 0xff)).toShort() / 32768.0
            sum += sample * sample
        }
        val rms = sqrt(sum / (pcm.size / 2))
        return if (rms > 0) 20 * log10(rms) else -90.0
    }

    // MARK: Notifications and tile

    private fun channels(): NotificationManager {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("mic", "Mic on", NotificationManager.IMPORTANCE_LOW))
        manager.createNotificationChannel(NotificationChannel("notice", "Mic turned off", NotificationManager.IMPORTANCE_DEFAULT))
        return manager
    }

    fun statusText(): String = when (phase) {
        Phase.SEARCHING -> "Looking for your Mac…"
        Phase.CONNECTING -> "Connecting to ${macName ?: "your Mac"}…"
        Phase.CONNECTED -> "Mic on · ${macName ?: "Mac"}" + if (macListening) " · listening" else ""
    }

    private fun notification(): Notification {
        channels()
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, MicService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE)
        val talk = PendingIntent.getService(this, 2, Intent(this, MicService::class.java).setAction(ACTION_TALK),
            PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, "mic")
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle(statusText())
            .setContentText(if (phase == Phase.CONNECTED) "Talk starts and stops dictation on the Mac" else detail)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(null, "Talk", talk).build())
            .addAction(Notification.Action.Builder(null, "Turn off", stop).build())
            .build()
    }

    private fun updateNotification() {
        if (running) channels().notify(NOTIFICATION, notification())
    }

    private fun showNotice(text: String) {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        channels().notify(NOTICE, Notification.Builder(this, "notice")
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle("PhoneCam Mic is off")
            .setContentText(text)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build())
    }

    private fun updateTile() =
        TileService.requestListeningState(this, ComponentName(this, MicTileService::class.java))

    private fun log(text: String) = Log.i(TAG, text)
}

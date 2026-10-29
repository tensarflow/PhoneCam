package com.arteq.btmicspike

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
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import java.io.DataInputStream
import java.io.IOException
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

private const val TAG = "BTMicSpike"

/**
 * Captures the mic, encodes 20 ms Opus packets and sends them to the Mac over a BLE L2CAP channel.
 * The Mac is the GATT server: we scan for its service, read the channel's PSM and connect to it.
 */
@SuppressLint("MissingPermission")
class StreamService : Service() {
    companion object {
        @Volatile var instance: StreamService? = null
        const val ACTION_STOP = "stop"
        const val EXTRA_ENCRYPTED = "encrypted"
        private const val SAMPLE_RATE = 48000
        private const val FRAME = 960 // 20 ms
        private const val QUEUE_LIMIT = 25 // 500 ms of audio
    }

    // Read by the activity for its status screen.
    @Volatile var state = "Idle"
    @Volatile var startedAt = 0L
    @Volatile var connectedAt = 0L
    @Volatile var packetsEncoded = 0
    @Volatile var packetsSent = 0
    @Volatile var bytesSent = 0L
    @Volatile var queueDrops = 0
    @Volatile var notConnectedDrops = 0
    @Volatile var maxWriteMillis = 0L
    @Volatile var reconnects = 0
    @Volatile var phy = "?"
    @Volatile var levelDb = -90.0
    @Volatile var batteryStart = 0
    @Volatile var encrypted = true
    @Volatile var bundle = 3
    @Volatile var bitrate = 32000
    @Volatile var writes = 0

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
    private var sequence = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutdown()
            stopSelf()
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        encrypted = intent?.getBooleanExtra(EXTRA_ENCRYPTED, true) ?: true
        bundle = (intent?.getIntExtra("bundle", 3) ?: 3).coerceIn(1, 10)
        bitrate = intent?.getIntExtra("bitrate", 32000) ?: 32000
        log("bundle $bundle packets, $bitrate bit/s")
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        instance = this
        running = true
        startedAt = SystemClock.elapsedRealtime()
        batteryStart = battery()
        bluetooth = getSystemService(BluetoothManager::class.java)
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "btmicspike:stream").apply { acquire(4 * 60 * 60 * 1000L) }
        audioThread = Thread(::audioLoop, "audio").apply { start() }
        senderThread = Thread(::sendLoop, "sender").apply { start() }
        scan()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    private fun shutdown() {
        if (!running) return
        running = false
        stopScan()
        closeLink()
        audioThread?.interrupt()
        senderThread?.interrupt()
        wakeLock?.takeIf { it.isHeld }?.release()
        instance = null
        state = "Stopped"
        log("stopped")
    }

    fun battery(): Int = getSystemService(BatteryManager::class.java).getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)

    fun currentMilliamps(): Int =
        getSystemService(BatteryManager::class.java).getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW) / 1000

    // MARK: Talk button

    fun talk(down: Boolean) {
        if (socket == null) return
        queue.offerFirst(Protocol.frame(if (down) Protocol.TALK_DOWN else Protocol.TALK_UP, ByteArray(0)))
        log("talk ${if (down) "down" else "up"}")
    }

    // MARK: Bluetooth

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!scanning) return
            stopScan()
            log("found ${result.device.address} rssi ${result.rssi}")
            connect(result.device)
        }

        override fun onScanFailed(errorCode: Int) {
            state = "Scan failed ($errorCode)"
            scanning = false
            retryLater()
        }
    }

    private fun scan() {
        if (!running || scanning) return
        val scanner = bluetooth.adapter?.bluetoothLeScanner
        if (scanner == null) {
            state = "Bluetooth is off"
            retryLater()
            return
        }
        state = "Looking for the Mac…"
        scanning = true
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(Protocol.SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
        log("scanning")
    }

    private fun stopScan() {
        if (!scanning) return
        scanning = false
        bluetooth.adapter?.bluetoothLeScanner?.stopScan(scanCallback)
    }

    private fun connect(device: BluetoothDevice) {
        state = "Connecting to ${device.address}…"
        gatt = device.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            log("gatt state $newState status $status")
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                g.setPreferredPhy(BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK,
                    BluetoothDevice.PHY_OPTION_NO_PREFERRED)
                main.postDelayed({ g.discoverServices() }, 300)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                linkLost("GATT disconnected (status $status)")
            }
        }

        override fun onPhyUpdate(g: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
            phy = "tx ${phyName(txPhy)} / rx ${phyName(rxPhy)}"
            log("phy $phy")
        }

        override fun onPhyRead(g: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) = onPhyUpdate(g, txPhy, rxPhy, status)

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val characteristic = g.getService(Protocol.SERVICE)?.getCharacteristic(Protocol.PSM_CHARACTERISTIC)
            if (characteristic == null) {
                linkLost("PhoneCam service not found")
                return
            }
            state = "Reading channel number…"
            g.readCharacteristic(characteristic)
        }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS || value.size < 2) {
                linkLost("PSM read failed (status $status)")
                return
            }
            val psm = (value[0].toInt() and 0xff) or ((value[1].toInt() and 0xff) shl 8)
            log("psm $psm")
            g.readPhy()
            Thread({ openChannel(g.device, psm) }, "l2cap-open").start()
        }
    }

    private fun phyName(phy: Int) = when (phy) {
        BluetoothDevice.PHY_LE_1M -> "1M"
        BluetoothDevice.PHY_LE_2M -> "2M"
        BluetoothDevice.PHY_LE_CODED -> "Coded"
        else -> "$phy"
    }

    private fun openChannel(device: BluetoothDevice, psm: Int) {
        state = "Opening audio channel (PSM $psm)…"
        try {
            val s = if (encrypted) device.createL2capChannel(psm) else device.createInsecureL2capChannel(psm)
            s.connect()
            socket = s
            queue.clear()
            connectedAt = SystemClock.elapsedRealtime()
            val model = "${Build.MANUFACTURER} ${Build.MODEL} (Android ${Build.VERSION.RELEASE})".toByteArray()
            queue.offerFirst(Protocol.frame(Protocol.HELLO, byteArrayOf(Protocol.VERSION.toByte()) + model))
            state = "Streaming"
            log("channel open")
            Thread({ readLoop(s) }, "reader").start()
        } catch (e: IOException) {
            linkLost("channel failed: ${e.message}")
        }
    }

    /** Answers the Mac's pings so it can measure round-trip time. */
    private fun readLoop(s: BluetoothSocket) {
        try {
            val input = DataInputStream(s.inputStream)
            while (running && socket === s) {
                val type = input.readUnsignedByte()
                val length = input.readUnsignedShort()
                val payload = ByteArray(length)
                input.readFully(payload)
                if (type == Protocol.PING) queue.offerFirst(Protocol.frame(Protocol.PONG, payload))
            }
        } catch (e: IOException) {
            if (socket === s) linkLost("read: ${e.message}")
        }
    }

    @Synchronized
    private fun linkLost(reason: String) {
        if (!running) return
        log("link lost: $reason")
        state = "Reconnecting… ($reason)"
        closeLink()
        reconnects++
        retryLater()
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
        connectedAt = 0
    }

    private fun retryLater() {
        main.removeCallbacksAndMessages(null)
        main.postDelayed({ if (running && socket == null && gatt == null) scan() }, 2000)
    }

    // MARK: Sending

    /**
     * Writes control frames at once and audio in bundles of [bundle] packets per L2CAP write:
     * the link carries a limited number of writes per second, not a limited number of bytes.
     */
    private fun sendLoop() {
        val pending = ArrayList<ByteArray>()
        var pendingSocket: BluetoothSocket? = null
        while (running) {
            val frame = try { queue.poll(1, TimeUnit.SECONDS) } catch (_: InterruptedException) { return } ?: continue
            val s = socket ?: continue
            // Audio bundled for a previous connection is stale.
            if (s !== pendingSocket) {
                pending.clear()
                pendingSocket = s
            }
            val isAudio = frame[0].toInt() == Protocol.AUDIO
            if (isAudio) {
                pending.add(frame)
                if (pending.size < bundle) continue
            }
            val data = if (isAudio) pending.reduce { a, b -> a + b } else frame
            val start = SystemClock.elapsedRealtime()
            try {
                s.outputStream.write(data)
                if (isAudio) {
                    packetsSent += pending.size
                    bytesSent += data.size
                    writes++
                    pending.clear()
                }
            } catch (e: IOException) {
                pending.clear()
                if (socket === s) linkLost("write: ${e.message}")
                continue
            }
            maxWriteMillis = max(maxWriteMillis, SystemClock.elapsedRealtime() - start)
        }
    }

    // MARK: Audio

    @SuppressLint("MissingPermission")
    private fun audioLoop() {
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val recorder = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, max(minBuffer, FRAME * 2 * 8))
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, SAMPLE_RATE, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, FRAME * 2)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()
        log("encoder ${encoder.name}")
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
            log("audio stopped: $e")
            state = "Audio error: ${e.message}"
        } finally {
            recorder.stop()
            recorder.release()
            encoder.stop()
            encoder.release()
        }
    }

    private fun enqueue(packet: ByteArray, captureMillis: Long) {
        packetsEncoded++
        val frame = Protocol.audio(sequence, captureMillis, packet)
        sequence = (sequence + 1) and 0xffff
        if (socket == null) {
            notConnectedDrops++
            return
        }
        // Stay close to real time: drop the oldest audio if the link falls behind.
        while (queue.size >= QUEUE_LIMIT) {
            val oldest = queue.firstOrNull { it[0].toInt() == Protocol.AUDIO } ?: break
            if (queue.removeFirstOccurrence(oldest)) queueDrops++
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

    // MARK: Notification

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("stream", "Streaming", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, StreamService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, "stream")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Streaming mic to the Mac")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private fun log(text: String) = Log.i(TAG, text)
}

package com.arteq.phonecam.mic

import java.util.UUID

/**
 * Messages on the L2CAP channel to PhoneCam: `u8 type | u16 length (big-endian) | payload`.
 * Keep in sync with App/BluetoothMic.swift.
 */
object Protocol {
    val SERVICE: UUID = UUID.fromString("7A3F0001-5C1E-4B7E-9B1A-2F6D8C4E0A11")
    val PSM_CHARACTERISTIC: UUID = UUID.fromString("7A3F0002-5C1E-4B7E-9B1A-2F6D8C4E0A11")

    const val VERSION = 2
    const val HELLO = 0x01      // phone → Mac: version, phone name
    const val WELCOME = 0x02    // Mac → phone: version, Mac name
    const val AUDIO = 0x10      // phone → Mac: u16 sequence, u32 capture ms, one 20 ms Opus packet
    const val TALK_DOWN = 0x20
    const val TALK_UP = 0x21
    const val STATUS = 0x30     // Mac → phone: u8 flags (1 = an app is recording PhoneCam Microphone)
    const val DISARM = 0x31     // Mac → phone: u8 reason (1 = unused for a while, 2 = turned off on the Mac)
    const val ACK = 0x32        // Mac → phone: u16 newest sequence received
    const val PING = 0x40
    const val PONG = 0x41

    const val DISARM_IDLE = 1
    const val DISARM_TURNED_OFF = 2

    fun frame(type: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        val out = ByteArray(3 + payload.size)
        out[0] = type.toByte()
        out[1] = (payload.size shr 8).toByte()
        out[2] = payload.size.toByte()
        payload.copyInto(out, 3)
        return out
    }

    fun audio(sequence: Int, captureMillis: Long, opus: ByteArray): ByteArray {
        val payload = ByteArray(6 + opus.size)
        payload[0] = (sequence shr 8).toByte()
        payload[1] = sequence.toByte()
        payload[2] = (captureMillis shr 24).toByte()
        payload[3] = (captureMillis shr 16).toByte()
        payload[4] = (captureMillis shr 8).toByte()
        payload[5] = captureMillis.toByte()
        opus.copyInto(payload, 6)
        return frame(AUDIO, payload)
    }

    fun long(value: Long) = ByteArray(8) { (value shr (56 - 8 * it)).toByte() }

    fun readLong(bytes: ByteArray) = bytes.fold(0L) { acc, b -> (acc shl 8) or (b.toLong() and 0xff) }
}

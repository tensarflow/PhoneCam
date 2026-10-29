package com.arteq.btmicspike

import java.util.UUID

/** Wire format shared with the Mac spike: u8 type | u16 length (big-endian) | payload. */
object Protocol {
    val SERVICE: UUID = UUID.fromString("7A3F0001-5C1E-4B7E-9B1A-2F6D8C4E0A11")
    val PSM_CHARACTERISTIC: UUID = UUID.fromString("7A3F0002-5C1E-4B7E-9B1A-2F6D8C4E0A11")

    const val VERSION = 1
    const val HELLO = 0x01
    const val AUDIO = 0x10
    const val TALK_DOWN = 0x20
    const val TALK_UP = 0x21
    const val PING = 0x40
    const val PONG = 0x41

    fun frame(type: Int, payload: ByteArray): ByteArray {
        val out = ByteArray(3 + payload.size)
        out[0] = type.toByte()
        out[1] = (payload.size shr 8).toByte()
        out[2] = payload.size.toByte()
        payload.copyInto(out, 3)
        return out
    }

    /** Audio payload: u16 sequence, u32 capture time in ms (phone clock), then one Opus packet. */
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
}

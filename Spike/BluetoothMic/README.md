# Bluetooth mic spike

Milestone 1 of [Docs/bluetooth-mic-spec.md](../../Docs/bluetooth-mic-spec.md): does Opus over a BLE
L2CAP channel hold up well enough to dictate with, on crowded networks, with the phone as the mic?

- `Mac/`: **BT Mic Spike**, an app that advertises as "PhoneCam", receives the audio, plays it into
  **PhoneCam Microphone** and taps **Right Option** when you press Talk on the phone.
- `Android/`: **BT Mic Spike**, an app that records the mic (`VOICE_RECOGNITION`, 48 kHz mono), encodes
  Opus (32 kbit/s, 20 ms) and sends it in bundles of 3 packets per write.

## Build and run

```sh
Mac/build.sh && open Mac/build/BTMicSpike.app
cd Android && ./gradlew assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk
```

On the phone, open **BT Mic Spike** and tap **Start streaming**, or from the Mac:
`adb shell am start -n com.arteq.btmicspike/.MainActivity --ez start true [--ei bundle 3] [--ei bitrate 32000]`.
The first time, both devices ask to pair (compare the 6-digit code).

**Quit PhoneCam while testing.** Otherwise, when an app records from PhoneCam Microphone, PhoneCam starts
its USB session too and mixes cable audio into the Bluetooth audio.

## Test 1: dictate into FluidVoice

1. FluidVoice → microphone: **PhoneCam Microphone**.
2. Mac: allow **BT Mic Spike** in System Settings → Privacy & Security → **Accessibility** (asked the first
   time you press Talk, or click *Tap Right Option in 3 s*).
3. Put the cursor in a text field, tap **TALK** on the phone, speak, tap **TALK** again.
4. Check: does FluidVoice start and stop, is the first word there, is the transcript as good as with a
   headset mic?

## Test 2: 30 minutes somewhere crowded

1. Unplug the phone (USB charging hides the battery cost), start streaming, lock the phone, pocket it or
   put it on the table.
2. Keep AirPods and the Bluetooth keyboard/mouse connected to the Mac as usual. Dictate now and then.
3. After 30 min, note the battery % from the phone app and send the stats CSV from
   `~/Library/Logs/BTMicSpike/stats-*.csv` (one row per second).

**Go** if, over the 30 min: lost packets < 1%, underruns rare (a few per minute at most), no disconnects
(or quick reconnects), RTT mostly < 150 ms, battery < 5%/hour.

CSV columns: `packets_per_s` (should be ~50), `lost_per_s`, `jitter_ms`, `max_gap_ms`,
`underruns_per_s` (audible clicks), `buffer_ms` (jitter buffer fill), `rtt_ms`, `disconnects`.

## Findings so far (2026-10-29, desk, phone ~1 m from a Mac mini)

- Pairing works (LE Secure Connections numeric comparison). The first PSM read fails with GATT status
  133 while pairing is in progress; the retry after it succeeds.
- Both sides land on the **2M PHY**.
- **The link carries about 32 L2CAP writes per second, not a fixed number of bytes.** At one 20 ms packet
  per write (50/s) the Mac only got ~32/s, and Android's `write()` kept returning at once, so a backlog
  built up in the Bluetooth stack (RTT climbed to 6 s). Asking macOS for low connection latency changed
  nothing. **Bundling 3 packets per write (17 writes/s) fixed it:** 50 packets/s, 0 lost, 0 underruns,
  RTT 20–100 ms, jitter ~26 ms (from the 60 ms bundles), with a 100 ms buffer.
- Android doesn't push back when the link falls behind, so the real app needs its own flow control
  (for example, the Mac reporting what it received, and the phone dropping old audio).
- **Dictation works end to end:** with FluidVoice on PhoneCam Microphone, tapping TALK on the phone
  starts and stops FluidVoice (a synthetic Right Option `flagsChanged` event reaches its event tap) and
  the transcript comes out right.
- **Decision (2026-10-29): go, without the crowded-place test.** The owner skipped Test 2, so
  crowded-place behaviour, 30-minute stability and battery drain are unmeasured. The real app covers
  this with flow control, automatic reconnect and the per-second stats kept in a debug view.

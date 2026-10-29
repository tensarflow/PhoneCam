# Spec: Phone mic over Bluetooth (PhoneCam companion app)

Status: draft, 2026-10-29

## Why

The main use is dictating into FluidVoice on a Mac without a built-in microphone, usually on crowded
guest Wi-Fi. Guest networks isolate clients, so phone ↔ Mac over Wi-Fi isn't reliable. Today PhoneCam
needs a USB cable, USB debugging and adb.

Goal: tap once on the phone, and **PhoneCam Microphone** gets the phone's mic over Bluetooth, with a
push-to-talk button on the phone that drives FluidVoice. No network, no cable, no Developer options.

## Scope

**v1**
- Android app "PhoneCam Mic": arm/disarm the mic, push-to-talk, Quick Settings tile, notification controls.
- Audio: 48 kHz mono, Opus ~32 kbit/s, over a BLE L2CAP channel (CoC).
- PhoneCam: a Bluetooth link that feeds the existing `MicFeed` → "PhoneCam Microphone" path, and
  presses FluidVoice's shortcut when push-to-talk is used on the phone.

**Not in v1**
- Camera over Bluetooth (not enough bandwidth).
- The Mac waking the phone's mic on its own. Android 14+ doesn't let an app start the microphone
  from the background, so the phone always starts a session.
- Volume-key push-to-talk (see Later).
- Wi-Fi transport for the app (the protocol below is transport-neutral, so it can be added later).

## User flow

1. **Pair once.** In the app, tap *Add Mac*. It scans for PhoneCam's BLE service, lists nearby Macs,
   and connects. Both sides show the OS Bluetooth pairing prompt (LE Secure Connections, numeric
   comparison). The app remembers the Mac.
2. **Arm.** Tap the tile or the in-app button → a foreground service starts with a notification
   ("Mic ready for <Mac name>"), connects to the Mac, and starts streaming. The menu-bar icon in
   PhoneCam shows a "phone mic" badge.
3. **Dictate.** Either:
   - press FluidVoice's shortcut on the Mac as usual, or
   - tap **Talk** on the phone (in-app button, or the notification action). PhoneCam taps
     FluidVoice's shortcut (**Right Option**) for you. Tap again to stop (FluidVoice is in toggle
     mode on this Mac: `PressAndHoldMode = 0`); in hold mode, the in-app button works as hold-to-talk.
4. **Disarm.** Tap the tile again, *Stop* in the notification, or automatically after 10 min with no
   push-to-talk and no app recording from PhoneCam Microphone (PhoneCam tells the phone).

The mic streams the whole time it's armed, so the first word is never cut off. That's affordable at
32 kbit/s, and Android's green mic indicator makes it obvious it's on.

## Architecture

```
Android "PhoneCam Mic"                                Mac (PhoneCam.app)
┌──────────────────────────────┐   BLE L2CAP CoC    ┌──────────────────────────────────┐
│ AudioRecord (VOICE_RECOGNITION│  Opus frames +     │ BluetoothLink (CoreBluetooth     │
│  48 kHz mono)                 │ ─control msgs────▶ │  peripheral, publishes L2CAP PSM)│
│ MediaCodec Opus encoder       │ ◀──────────────── │ OpusDecoder → MicFeed (mono→st.) │──▶ PhoneCam Microphone
│ Foreground service            │                    │ HotkeySender (CGEvent)           │──▶ FluidVoice shortcut
│ (microphone|connectedDevice)  │                    └──────────────────────────────────┘
└──────────────────────────────┘
```

**Roles.** The Mac is the BLE *peripheral*: PhoneCam is a long-running menu-bar app, so it can
advertise all the time. The phone is the *central* and only connects when the user arms the mic,
which avoids Android's background-scan limits.

- PhoneCam advertises service `PHONECAM_MIC_SERVICE` (new 128-bit UUID) with one encrypted, readable
  characteristic holding the L2CAP PSM, from `CBPeripheralManager.publishL2CAPChannel(withEncryption: true)`.
- The phone connects over GATT, reads the PSM (this triggers pairing the first time), then opens
  `BluetoothDevice.createL2capChannel(psm)` and uses the socket's streams.
- Request LE 2M PHY and a short connection interval (7.5–15 ms) for low jitter. 32 kbit/s is under
  10% of what BLE carries, so a crowded 2.4 GHz band has plenty of headroom.

## Protocol

L2CAP CoC is a byte stream on both platforms, so messages are length-prefixed:

```
u8 type | u16 length (big-endian) | payload
```

| type | direction | payload |
|---|---|---|
| `0x01 hello` | phone → Mac | protocol version (u8), phone model (UTF-8) |
| `0x02 welcome` | Mac → phone | protocol version, Mac name, push-to-talk mode (toggle/hold) |
| `0x10 audio` | phone → Mac | u16 sequence number, u32 capture time (ms), one Opus packet (20 ms, 48 kHz mono). Several audio messages go in one L2CAP write (3 by default): the link carries about 32 writes per second, see the spike findings in `Spike/BluetoothMic/README.md` |
| `0x20 talk_down` / `0x21 talk_up` | phone → Mac | none |
| `0x30 status` | Mac → phone | flags: an app is recording PhoneCam Microphone; FluidVoice is listening (best guess) |
| `0x31 disarm` | Mac → phone | reason (idle, user turned it off on the Mac) |
| `0x40 ping` / `0x41 pong` | both | u32 timestamp, for round-trip time in the debug view |

The sequence number lets the Mac detect lost packets and fill gaps with Opus packet loss
concealment instead of silence.

## Android app

- Kotlin, `minSdk 29` (Android 10: first version with both L2CAP CoC and the platform Opus encoder),
  `targetSdk 36`.
- Target device: **Samsung Galaxy S22 (SM-S901E), Android 16 / One UI 8** (SDK 36, patch 2026-08-05).
  Checked over adb: `c2.android.opus.encoder` is present, and the Bluetooth stack has
  `HidDeviceService` enabled (`bluetooth.profile.hid.device.enabled=true`).
- Samsung battery management: the first-run screen asks to exempt the app from battery optimization
  and points to *Settings → Battery → Background usage limits → Never sleeping apps*.
- Permissions: `RECORD_AUDIO`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` (`neverForLocation`),
  `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS`.
- **Starting the service.** Android 14+ only allows starting a microphone foreground service while
  the app is visible. The tile and the notification therefore open a transparent trampoline
  activity that starts the service and finishes at once (`TileService.startActivityAndCollapse`
  with a `PendingIntent`).
- Audio: `AudioRecord` with `MediaRecorder.AudioSource.VOICE_RECOGNITION` (the phone's noise
  suppression, no AGC pumping) → `MediaCodec` `audio/opus`, 48 kHz mono, 32 kbit/s, 20 ms frames,
  in-band FEC on.
- Reconnect: if the link drops while armed, keep capturing and retry the connection with backoff for
  60 s, then disarm with a notification.
- UI: one screen (paired Mac, Arm switch, big Talk button, input level meter, link quality), the
  tile, and the ongoing notification with *Talk* and *Stop*.
- Code lives in the PhoneCam repo under `Android/`, so the protocol and both ends version together.

## PhoneCam (Mac) changes

| File | Change |
|---|---|
| `App/BluetoothLink.swift` (new) | `CBPeripheralManager`: advertise, publish the L2CAP channel, read framed messages, track the connected phone |
| `App/OpusDecoder.swift` (new) | Opus → 48 kHz Float32 using AudioToolbox's `AudioConverter` (`kAudioFormatOpus`); fall back to bundled libopus if that turns out unreliable |
| `App/HotkeySender.swift` (new) | Records a shortcut in the panel (default **Right Option**) and posts it with `CGEvent` on `talk_down`/`talk_up`. Right Option is a modifier-only key, so it's a `flagsChanged` event with keycode 61 (`kVK_RightOption`) and flags `.maskAlternate` + `0x40` (`NX_DEVICERALTKEYMASK`) for down, then no flags for up. FluidVoice listens with a `CGEventTap` (its binary imports `CGEventTapCreate`), so events posted at `.cghidEventTap` should reach it. Needs Accessibility permission, asked the first time it's used |
| `App/MicFeed.swift` | Accept mono Float32 as well as stereo Int16; make the buffer size per source: ~30 ms for USB, ~100 ms target / 250 ms max for Bluetooth |
| `App/AppModel.swift` | One audio source at a time: the USB session's audio when it's running, otherwise Bluetooth. Reset `MicFeed` when switching. Send `status`, and `disarm` after 10 min idle |
| `App/PhoneCamApp.swift` | Panel section "Phone app (Bluetooth)": paired phone, link state, level meter, the FluidVoice shortcut, idle timeout |
| `App/Info.plist` | `NSBluetoothAlwaysUsageDescription` |

The app isn't sandboxed (the entitlements only contain `system-extension.install`), so it doesn't
need the Bluetooth sandbox entitlement. The Core Audio driver doesn't change.

## Targets

- From tapping Talk until the audio reaches FluidVoice: under 200 ms.
- No audible dropouts in 30 minutes in a busy café, with the phone in a pocket or on the table.
- Works with the phone's Wi-Fi off.
- Battery: under 5% per hour while armed (to be measured).
- Arming takes at most 2 s from tapping the tile.

## Milestones

1. **Spike (go/no-go).** Minimal Android and Mac programs that only stream Opus over L2CAP. Measure
   packet loss, jitter and battery for 30 min somewhere crowded, with AirPods and a Bluetooth keyboard
   also connected to the Mac. If it fails, fall back to classic Bluetooth RFCOMM. Also check that a
   synthetic Right Option tap starts and stops FluidVoice.
2. **Audio into PhoneCam Microphone**, armed from the app. FluidVoice is driven from the Mac keyboard.
3. **Talk button** + `HotkeySender`.
4. **Tile, notification, reconnect, idle disarm, panel UI.**
5. Polish: level meter, link quality, battery measurement.

## Open questions

- ~~Which phone?~~ Galaxy S22, Android 16 / One UI 8 (see Android app).
- ~~FluidVoice's shortcut?~~ Right Option, toggle mode. Confirmed in the spike (2026-10-29): a
  synthetic Right Option tap from the Mac starts and stops FluidVoice. The Bluetooth-keyboard
  fallback (`BluetoothHidDevice`, HID usage `0xE6`) isn't needed, but it remains an option for
  dropping the Accessibility permission.
- FluidVoice's microphone is set to a specific device (`MicrophoneSelectionMode = manual`, currently
  a Bluetooth headset). It has to be switched to PhoneCam Microphone once, or this feature won't be
  heard.
- Does Apple's AudioToolbox Opus decoder handle raw packets with FEC well enough, or do we need libopus?
- Distribution: sideloaded APK from GitHub releases (simplest), or the Play Store later.

## Later

- Volume-key push-to-talk while armed, using a `MediaSession` with a remote volume provider (works
  with the screen off on most phones; no accessibility service).
- A Wi-Fi/Tailscale transport using the same protocol.
- Mic-only mode for the USB path (`video=false`), so dictating over the cable doesn't start the camera.

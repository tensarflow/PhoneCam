# PhoneCam Mic (Android)

Sends the phone's microphone to PhoneCam on the Mac over Bluetooth, so it shows up as
**PhoneCam Microphone** without a cable or a shared Wi-Fi network. Its **TALK** button presses
Right Option on the Mac, FluidVoice's dictation shortcut. Design: [Docs/bluetooth-mic-spec.md](../Docs/bluetooth-mic-spec.md).

## Use

1. In PhoneCam on the Mac, turn on **Use the phone's microphone → Also over Bluetooth**.
2. Open PhoneCam Mic and tap **Turn mic on** (or use its Quick Settings tile). The first time, both
   devices ask to pair: check the codes match.
3. Pick **PhoneCam Microphone** in FluidVoice (or any app). Tap **TALK** to start dictating and again to
   stop. The notification has **Talk** and **Turn off** too, also on the lock screen.

The mic turns itself off after 10 minutes with nothing recording on the Mac and no Talk, or after a
minute of not reaching the Mac. Tap **Allow running in the background** once, so Samsung's battery
manager doesn't stop it.

## Build

Needs JDK 17 and the Android SDK (`local.properties` with `sdk.dir=…`).

```sh
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## How it works

- `MicService`: foreground service. `AudioRecord` (`VOICE_RECOGNITION`, 48 kHz mono) → `MediaCodec` Opus
  (32 kbit/s, 20 ms) → BLE L2CAP channel to PhoneCam, 3 packets per write (the link carries ~32 writes
  per second). PhoneCam acknowledges five times a second; when it's more than 500 ms behind, the phone
  drops audio instead of letting the delay grow.
- `ToggleActivity`: invisible screen the tile uses, since Android only lets an app start the microphone
  while one of its screens is showing.
- `Protocol`: the message format, shared with `App/BluetoothMic.swift`.

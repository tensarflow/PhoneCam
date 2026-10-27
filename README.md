<p align="center"><img src="Docs/icon.png" width="160" alt="PhoneCam icon"></p>

# PhoneCam

Use your Android phone as a plug-and-play USB webcam on your Mac.

Plug the phone in and a camera called **PhoneCam** — and, optionally, a microphone called
**PhoneCam Microphone** — show up in Teams, Zoom, FaceTime, Meet, OBS, Photo Booth: anything that
uses a camera or mic. No OBS, no window to keep open, no app on the phone.

- **Menu bar app** with a live preview of what others see
- **USB only**: low latency, no Wi-Fi drops, hardware H.264 decoding
- **Back or front camera**, 720p or 1080p at 30 fps
- **The phone's microphone** as a Mac input (raw 48 kHz stereo over USB, ~30 ms buffer)
- **Rotate in 90° steps**, so the phone can sit however you like; fill the frame or fit with bars
- **Reconnects by itself** when you replug the phone or something else borrows its camera
- **Runs the phone camera only when needed** (or always — your choice): it starts when an app opens
  PhoneCam and stops a few seconds after the last one closes
- **Keeps the phone awake** while streaming (phones release the camera when the screen sleeps)

## How it works

```
Android phone                         Mac
┌──────────────────┐   USB / adb   ┌────────────────────────────┐      ┌───────────────────────┐
│ scrcpy server     │ ───H.264────▶ │ PhoneCam.app (menu bar)    │      │ PhoneCam Camera       │
│ (camera mode,     │               │ VideoToolbox decode,       │ ───▶ │ (Core Media IO        │ ──▶ Teams, Zoom…
│  pushed over adb) │               │ rotate/scale on the GPU    │ sink │  camera extension)    │
└──────────────────┘               └────────────────────────────┘      └───────────────────────┘
```

- The app polls `adb` for a phone, pushes the bundled [scrcpy](https://github.com/Genymobile/scrcpy)
  server and starts it with `video_source=camera`. Nothing is installed on the phone.
- The H.264 stream is decoded with VideoToolbox, rotated and fitted to 1920×1080 with Core Image,
  and written into the extension's **sink stream**.
- The camera extension (a system extension) forwards those frames to its **source stream**, which is
  what video apps see. With no phone it shows a placeholder saying what's going on.
- For the microphone, the same server also captures the phone's mic as raw PCM. PhoneCam plays it into
  a hidden output device of the bundled **PhoneCam Microphone** Core Audio driver
  (`Driver/PhoneCamMic.c`), which loops it straight into its visible input device.

## Requirements

- macOS 14 or later (tested on macOS 27, Apple Silicon)
- An Android phone with **Android 12 or later** and **USB debugging** enabled
  (Settings → About phone → tap *Build number* 7 times → Developer options → USB debugging)
- `adb` — `brew install android-platform-tools`, or the Android SDK's platform-tools
- To build: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`),
  and a **paid Apple Developer team** — macOS only loads camera extensions signed with a
  provisioning profile that allows system extensions

## Build and install

1. Set your team and a bundle ID prefix you own:

   ```sh
   cat > Config/Signing.local.xcconfig <<'EOF'
   DEVELOPMENT_TEAM = ABCDE12345
   BUNDLE_ID_PREFIX = com.yourname
   EOF
   ```

2. Generate the project and build (Xcode must be signed in to that team):

   ```sh
   xcodegen generate
   xcodebuild -project PhoneCam.xcodeproj -scheme PhoneCam -configuration Release \
     -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```

3. Install to **/Applications** (system extensions only load from there) and open it:

   ```sh
   ditto build/Build/Products/Release/PhoneCam.app /Applications/PhoneCam.app
   open /Applications/PhoneCam.app
   ```

4. Approve the camera once: **System Settings → General → Login Items & Extensions →
   Camera Extensions → PhoneCam**.

5. Plug in the phone and tap **Allow** on its USB debugging prompt.

6. Optional, for the microphone: in the panel, click **Install…** next to *Use the phone's
   microphone*. macOS asks for your password; PhoneCam copies the driver to
   `/Library/Audio/Plug-Ins/HAL` and restarts Core Audio (Mac audio pauses for a moment).
   When the driver changes, bump its `CFBundleVersion` in `project.yml` and PhoneCam offers an update.

When you change the camera extension, bump `CURRENT_PROJECT_VERSION` in `project.yml` so macOS
replaces the installed one.

## Use

Click the menu bar icon:

| | |
|---|---|
| Switch | Turns the camera on or off |
| Phone camera | **When used**: the phone's camera runs only while an app uses PhoneCam (or the panel is open), starting in about 2–3 s. **Always on**: it runs whenever the phone is plugged in, so the picture is instant |
| Preview | What video apps receive; ↺ ↻ rotate it |
| Camera | Back or front |
| Rotation | 0°, 90°, 180°, 270° (90°/270° capture 4:3 so the crop keeps detail) |
| Framing | **Fill** crops to fill 16:9, **Fit** shows everything with bars |
| Quality | 720p or 1080p |

Then pick **PhoneCam** as the camera (and **PhoneCam Microphone** as the mic) in your video app. Turn on **Open PhoneCam at login** and the
camera is ready whenever you plug the phone in.

## Troubleshooting

- **"Reconnecting… camera is busy"** — face unlock or the phone's camera app took the camera.
  Leave the phone locked and untouched while streaming; PhoneCam takes the camera back on its own.
- **Stuck on "Waiting for the phone"** — unlock the phone and accept the USB debugging prompt.
- **macOS switched my Mac's default input to PhoneCam Microphone** — macOS tends to select newly
  added inputs. Pick your usual one again in System Settings → Sound → Input.
- **Uninstall the microphone**: `sudo rm -rf /Library/Audio/Plug-Ins/HAL/PhoneCamMic.driver && sudo killall coreaudiod`
- **App sees no PhoneCam camera** — check the extension is enabled in System Settings, and restart
  the video app (most apps only look for cameras at launch).
- Logs: `~/Library/Logs/PhoneCam.log` (app) and
  `log show --predicate 'subsystem ENDSWITH "PhoneCam.CameraExtension"' --last 10m` (extension).

## License

[Apache License 2.0](LICENSE). Bundles the scrcpy server (Apache 2.0, © Genymobile and
Romain Vimont) — see [NOTICE](NOTICE).

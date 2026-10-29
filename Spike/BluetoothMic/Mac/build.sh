#!/bin/sh
# Builds BTMicSpike.app next to this script and signs it with the Apple Development identity,
# so macOS keeps its Bluetooth and Accessibility permissions across rebuilds.
set -e
cd "$(dirname "$0")"
APP=build/BTMicSpike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/BTMicSpike" main.swift \
  -framework AppKit -framework CoreBluetooth -framework AudioToolbox -framework AVFoundation -framework CoreAudio
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>BTMicSpike</string>
	<key>CFBundleIdentifier</key><string>com.arteq.BTMicSpike</string>
	<key>CFBundleName</key><string>BT Mic Spike</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSBluetoothAlwaysUsageDescription</key><string>Receives the phone's microphone over Bluetooth.</string>
</dict>
</plist>
EOF
IDENTITY="${SIGN_IDENTITY:-Apple Development: Tayyip Ensar Ozkaya (CJ9978JT7A)}"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"

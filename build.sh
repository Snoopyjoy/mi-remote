#!/bin/bash
# Build MiRemote.app (ad-hoc signed) into ./dist
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/MiRemote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/MiRemote" Sources/main.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.miremote.daemon</string>
  <key>CFBundleName</key><string>MiRemote</string>
  <key>CFBundleExecutable</key><string>MiRemote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSBackgroundOnly</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>MiRemote only remaps the already-paired Xiaomi remote.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

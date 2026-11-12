#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_root="$(mktemp -d -t moriq-managed-audio)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/Test.app/Contents/MacOS"
cat > "$test_root/Test.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>CaptionTest</string><key>CFBundleIdentifier</key><string>local.moriq.captiontest</string><key>CFBundleName</key><string>CaptionTest</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -DDEBUG MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift Tests/ManagedSpeechSystemAudio/main.swift -o "$test_root/Test.app/Contents/MacOS/CaptionTest"
python3 Tests/ManagedSpeechSystemAudio/test_network.py "$test_root/Test.app/Contents/MacOS/CaptionTest"

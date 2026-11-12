#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_root="$(mktemp -d -t moriq-caption-integrated)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/Test.app/Contents/MacOS"
cat > "$test_root/Test.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>CaptionTest</string><key>CFBundleIdentifier</key><string>local.moriq.captiontest</string><key>CFBundleName</key><string>CaptionTest</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
sed 's/private struct LiveCaptionView: View/struct LiveCaptionView: View/' MORIQ/LiveCaptions.swift > "$test_root/LiveCaptions.swift"
swiftc "$test_root/LiveCaptions.swift" MORIQ/LocalWhisperCaptions.swift MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift Tests/ManagedSpeech/TokenStub.swift Tests/LiveCaptionsIntegrated/main.swift -o "$test_root/Test.app/Contents/MacOS/CaptionTest"
"$test_root/Test.app/Contents/MacOS/CaptionTest"

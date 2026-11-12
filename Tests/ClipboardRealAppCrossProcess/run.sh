#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app=${1:?pass path to signed Debug MORIQ.app}
binary="$app/Contents/MacOS/MORIQ"
tmpdir=$(mktemp -d "${TMPDIR}moriq-external.XXXXXX")
uid=$(uuidgen)
service="local.moriq.test.signed.$uid"
board="local.moriq.external.test.$uid"
helper="$tmpdir/Receiver.app/Contents/MacOS/fixture"
cleanup() { "$binary" --verify-signed-clipboard cleanup "$service" "$tmpdir" "$service" >/dev/null 2>&1 || true; if [[ -x "$helper" ]]; then "$helper" cleanup "$board" >/dev/null 2>&1 || true; fi; rm -rf "$tmpdir"; }
trap cleanup EXIT
mkdir -p "$tmpdir/Receiver.app/Contents/MacOS"
swiftc Tests/ClipboardRealAppCrossProcess/External.swift -o "$tmpdir/Receiver.app/Contents/MacOS/fixture"
cat > "$tmpdir/Receiver.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.moriq.external.fixture</string><key>CFBundleExecutable</key><string>fixture</string><key>CFBundleName</key><string>MORIQ Test Receiver</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
"$binary" --verify-signed-clipboard captureExternal "$service" "$tmpdir" "$service" "$board" "$helper"
"$binary" --verify-signed-clipboard restoreExternal "$service" "$tmpdir" "$service" "$board" "$helper"

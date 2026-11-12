#!/bin/sh
# Read-only source introspection with temporary files; no network and no user files.
set -eu
if [ "$#" -ne 1 ] || [ ! -d "$1/Contents/Resources" ]; then
  echo '用法: sh Tests/CapabilityInventory/run.sh <待检查的 MORIQ.app 路径>' >&2
  exit 2
fi
project=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bundle=$(CDPATH= cd -- "$1" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/moriq-inventory.XXXXXXXX")
trap 'python3 -c '\''import shutil,sys; shutil.rmtree(sys.argv[1],ignore_errors=True)'\'' "$tmp"' EXIT HUP INT TERM
fixture="$tmp/Inventory.app/Contents"
mkdir -p "$fixture/MacOS" "$tmp/src"
ln -s "$bundle/Contents/Resources" "$fixture/Resources"
cat > "$fixture/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.moriq.capability-test</string><key>CFBundleExecutable</key><string>inventory</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
EOF
for name in ImageConverter DocumentConverter AudioConverter VideoConverter ExternalMediaConverter PDFPageExporter OCREngine; do cp "$project/MORIQ/$name.swift" "$tmp/src/$name.swift"; done
swiftc -suppress-warnings -parse-as-library "$tmp/src/"*.swift "$project/Tests/CapabilityInventory/main.swift" -o "$fixture/MacOS/inventory"
"$fixture/MacOS/inventory" "$tmp/src/DocumentConverter.swift"

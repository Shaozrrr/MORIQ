#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
candidate=${1:-"$HOME/Applications/MORIQ.app"}
resources="$candidate/Contents/Resources"
test -x "$resources/OfficeSuite/LibreOffice-$(uname -m).app/Contents/MacOS/soffice"
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-element-cover.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/check.app/Contents/MacOS" "$work/check.app/Contents/Resources"
ln -s "$resources/OfficeSuite" "$work/check.app/Contents/Resources/OfficeSuite"
cd "$root"
swiftc MORIQ/DocumentConverter.swift MORIQ/PDFPageExporter.swift MORIQ/OCREngine.swift MORIQ/ExternalMediaConverter.swift MORIQ/AudioConverter.swift MORIQ/VideoConverter.swift MORIQ/ImageConverter.swift Tests/HTMLWordElementCover/main.swift -o "$work/check.app/Contents/MacOS/check"
"$work/check.app/Contents/MacOS/check"

#!/bin/sh
# Run the text-content matrix against the resources inside a candidate app.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
candidate=${1:-/tmp/moriq-qa-office/Build/Products/Release/MORIQ.app}
resources="$candidate/Contents/Resources"
architecture=$(uname -m)
test -x "$resources/Pandoc/pandoc-$architecture"
test -x "$resources/OfficeSuite/LibreOffice-$architecture.app/Contents/MacOS/soffice"
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-document-matrix.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
app="$work/check.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
ln -s "$resources/Pandoc" "$app/Resources/Pandoc"
ln -s "$resources/OfficeSuite" "$app/Resources/OfficeSuite"
cd "$root"
swiftc MORIQ/DocumentConverter.swift MORIQ/PDFPageExporter.swift MORIQ/OCREngine.swift Tests/DocumentMatrix/main.swift -o "$app/MacOS/check"
"$app/MacOS/check"

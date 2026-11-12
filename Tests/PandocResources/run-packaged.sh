#!/bin/sh
# Verify conversion using the actual resources from a candidate application.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
candidate=${1:-/tmp/moriq-qa-office/Build/Products/Release/MORIQ.app}
resources="$candidate/Contents/Resources"
test -x "$resources/Pandoc/pandoc-arm64"
test -x "$resources/Pandoc/pandoc-x86_64"
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-pandoc-check.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
app="$work/check.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
ln -s "$resources/Pandoc" "$app/Resources/Pandoc"
ln -s "$resources/OfficeSuite" "$app/Resources/OfficeSuite"
cd "$root"
for test in PandocResources MarkdownImageFidelity HTMLImageFidelity MarkdownSyntax; do
  swiftc MORIQ/DocumentConverter.swift MORIQ/PDFPageExporter.swift MORIQ/OCREngine.swift "Tests/$test/main.swift" -o "$app/MacOS/$test"
  "$app/MacOS/$test"
done

#!/bin/sh
# Exercise both configurations with the same packaged engine used by the app.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root" || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-pdf-fidelity.XXXXXX") || exit 1
trap 'rm -r "$work"' EXIT HUP INT TERM
status=0
for mode in release debug; do
  flags=""
  [ "$mode" = debug ] && flags="-D DEBUG"
  echo "Testing $mode PDF conversion"
  # flags intentionally splits into compiler arguments for the debug build.
  app="$work/$mode.app/Contents"
  mkdir -p "$app/MacOS" "$app/Resources"
  ln -s "$root/Vendor/OfficeEngine" "$app/Resources/OfficeEngine"
  if swiftc $flags MORIQ/DocumentConverter.swift MORIQ/PDFPageExporter.swift MORIQ/OCREngine.swift Tests/PDFMixedContent/main.swift -o "$app/MacOS/check"; then
    "$app/MacOS/check" || status=1
  else
    status=1
  fi
  if swiftc $flags MORIQ/DocumentConverter.swift MORIQ/PDFPageExporter.swift MORIQ/OCREngine.swift Tests/PDFTableFidelity/main.swift -o "$app/MacOS/table"; then
    "$app/MacOS/table" || status=1
  else
    status=1
  fi
done
exit "$status"

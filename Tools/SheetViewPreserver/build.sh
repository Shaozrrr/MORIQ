#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-sheet-helper.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
javac -encoding UTF-8 -d "$work" "$root/Tools/SheetViewPreserver/SheetViewPreserver.java" "$root/Tools/SheetViewPreserver/OdsFontRestorer.java"
jar --create --file "$root/Vendor/OfficeEngine/sheet-view-preserver.jar" --main-class SheetViewPreserver -C "$work" .

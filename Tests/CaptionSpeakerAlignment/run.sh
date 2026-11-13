#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/moriq-caption-align.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
swiftc "$root/MORIQ/CaptionSpeakerAlignment.swift" "$root/Tests/CaptionSpeakerAlignment/main.swift" -o "$tmp/check"
"$tmp/check"

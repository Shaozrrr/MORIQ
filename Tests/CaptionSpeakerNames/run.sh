#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/moriq-speaker-labels.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
swiftc "$root/MORIQ/CaptionSpeakerNames.swift" "$root/Tests/CaptionSpeakerNames/main.swift" -o "$tmp/check"
"$tmp/check"

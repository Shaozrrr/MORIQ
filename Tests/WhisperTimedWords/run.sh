#!/bin/sh
# Requires the public LibriSpeech fixture /tmp/moriq-human-benchmark/0.wav.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
test -f /tmp/moriq-human-benchmark/0.wav
target=$(mktemp "${TMPDIR:-/tmp}/moriq-timed-bridge.XXXXXX")
trap 'rm -f "$target"' EXIT HUP INT TERM
swiftc -DDEBUG MORIQ/LocalWhisperCaptions.swift Tests/WhisperTimedWords/main.swift -o "$target"
"$target" "${1:-$root/Vendor/SpeechEngine/moriq-speech}"

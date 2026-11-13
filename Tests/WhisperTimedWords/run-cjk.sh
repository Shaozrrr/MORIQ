#!/bin/sh
set -eu
: "${MORIQ_PUBLIC_CJK_AUDIO:?provide public Mandarin WAV fixture}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
target=$(mktemp "${TMPDIR:-/tmp}/moriq-cjk-bridge.XXXXXX")
trap 'rm -f "$target"' EXIT HUP INT TERM
swiftc -DDEBUG MORIQ/LocalWhisperCaptions.swift Tests/WhisperTimedWords/CJK/main.swift -o "$target"
"$target" "${1:-$root/Vendor/SpeechEngine/moriq-speech}" "$MORIQ_PUBLIC_CJK_AUDIO"

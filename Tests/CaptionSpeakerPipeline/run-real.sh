#!/bin/sh
set -eu
: "${MORIQ_SPEAKER_HELPER:?Path to the built speaker engine}"
: "${MORIQ_SPEAKER_MODEL:?Path to the separately licensed model}"
: "${MORIQ_SPEAKER_SAMPLE:?Path to public two-speaker WAV}"
: "${MORIQ_SPEAKER_REFERENCE:?Path to public clip-level reference JSON}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
target=$(mktemp "${TMPDIR:-/tmp}/moriq-speaker-real.XXXXXX")
trap 'rm -f "$target"' EXIT HUP INT TERM
swiftc -DDEBUG MORIQ/LocalWhisperCaptions.swift MORIQ/SpeakerDiarizationBridge.swift MORIQ/CaptionSpeakerAlignment.swift MORIQ/CaptionSpeakerPipeline.swift Tests/CaptionSpeakerPipeline/Real/main.swift -o "$target"
"$target" "$MORIQ_SPEAKER_HELPER" "$MORIQ_SPEAKER_MODEL" "$root/Vendor/SpeechEngine/moriq-speech" "$MORIQ_SPEAKER_SAMPLE" "$MORIQ_SPEAKER_REFERENCE"

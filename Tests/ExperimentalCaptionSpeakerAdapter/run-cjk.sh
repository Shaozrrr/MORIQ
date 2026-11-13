#!/bin/sh
set -eu
: "${MORIQ_SPEAKER_HELPER:?Set local speaker engine}"
: "${MORIQ_SPEAKER_MODEL:?Set separately licensed local model}"
: "${MORIQ_PUBLIC_CJK_AUDIO:?Set public four-speaker Mandarin WAV}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-adapter-cjk.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$root"
swiftc -DDEBUG MORIQ/LocalWhisperCaptions.swift MORIQ/SpeakerDiarizationBridge.swift MORIQ/CaptionSpeakerAlignment.swift MORIQ/CaptionSpeakerPipeline.swift MORIQ/ExperimentalCaptionSpeakerAdapter.swift Tests/ExperimentalCaptionSpeakerAdapter/CJK/main.swift -o "$work/check"
"$work/check" "$MORIQ_SPEAKER_HELPER" "$MORIQ_SPEAKER_MODEL" Vendor/SpeechEngine/moriq-speech "$MORIQ_PUBLIC_CJK_AUDIO"

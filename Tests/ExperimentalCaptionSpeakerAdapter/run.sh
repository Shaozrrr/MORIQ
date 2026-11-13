#!/bin/sh
set -eu
# The public sample and separately licensed speaker model are external. Do not
# supply private audio to this test; it must not record from a microphone.
: "${MORIQ_SPEAKER_HELPER:?Set the path to a locally built MORIQSpeakerEngine}"
: "${MORIQ_SPEAKER_MODEL:?Set the path to the separately obtained Core ML model}"
: "${MORIQ_SPEAKER_SAMPLE:?Set the path to the public two-speaker WAV sample}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-experimental-speaker.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$root"
test -x "$MORIQ_SPEAKER_HELPER"
test -e "$MORIQ_SPEAKER_MODEL"
test -f "$MORIQ_SPEAKER_SAMPLE"
test -x Vendor/SpeechEngine/moriq-speech
test -f Vendor/SpeechEngine/ggml-base.bin
test -x Vendor/MediaEngine/ffmpeg
swiftc -DDEBUG MORIQ/LocalWhisperCaptions.swift MORIQ/SpeakerDiarizationBridge.swift \
  MORIQ/CaptionSpeakerAlignment.swift MORIQ/CaptionSpeakerPipeline.swift \
  MORIQ/ExperimentalCaptionSpeakerAdapter.swift Tests/ExperimentalCaptionSpeakerAdapter/main.swift \
  -o "$work/real"
"$work/real" "$MORIQ_SPEAKER_HELPER" "$MORIQ_SPEAKER_MODEL" \
  Vendor/SpeechEngine/moriq-speech "$MORIQ_SPEAKER_SAMPLE"
printf '#!/bin/sh\nexit 1\n' > "$work/immediate-failure"
chmod 700 "$work/immediate-failure"
swiftc -DDEBUG MORIQ/LocalWhisperCaptions.swift MORIQ/SpeakerDiarizationBridge.swift \
  MORIQ/CaptionSpeakerAlignment.swift MORIQ/CaptionSpeakerPipeline.swift \
  MORIQ/ExperimentalCaptionSpeakerAdapter.swift Tests/ExperimentalCaptionSpeakerAdapter/failure.swift \
  -o "$work/failure"
"$work/failure" Vendor/SpeechEngine/moriq-speech Vendor/SpeechEngine/ggml-base.bin "$work/immediate-failure"

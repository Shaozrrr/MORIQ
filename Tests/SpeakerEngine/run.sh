#!/bin/sh
set -eu
# The four-person sample and official CLI result are external, public test
# inputs; never point this script at a user's private recording.
: "${MORIQ_FLUIDAUDIO_SOURCE:?Set the FluidAudio checkout at the pinned revision}"
: "${MORIQ_SPEAKER_MODEL:?Set the compiled v2.1 CoreML model directory}"
: "${MORIQ_SPEAKER_SAMPLE:?Set the public mono 16kHz float32 PCM sample}"
: "${MORIQ_SPEAKER_REFERENCE:?Set official CLI JSON from the same sample}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-speaker-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$root/Tools/SpeakerEngine"
swift build -c release --scratch-path "$work/build"
cd "$root"
swiftc MORIQ/SpeakerDiarizationBridge.swift Tests/SpeakerEngine/main.swift -o "$work/real"
"$work/real" "$work/build/release/MORIQSpeakerEngine" "$MORIQ_SPEAKER_MODEL" "$MORIQ_SPEAKER_SAMPLE" "$MORIQ_SPEAKER_REFERENCE"
printf '#!/bin/sh\nexec sleep 30\n' > "$work/stall"
chmod 700 "$work/stall"
swiftc MORIQ/SpeakerDiarizationBridge.swift Tests/SpeakerEngine/failure.swift -o "$work/failure"
"$work/failure" "$work/stall"

#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
target=$(mktemp "${TMPDIR:-/tmp}/moriq-speaker-pipeline.XXXXXX")
trap 'rm -f "$target"' EXIT HUP INT TERM
swiftc -DDEBUG MORIQ/LocalWhisperCaptions.swift MORIQ/SpeakerDiarizationBridge.swift MORIQ/CaptionSpeakerAlignment.swift MORIQ/CaptionSpeakerPipeline.swift Tests/CaptionSpeakerPipeline/main.swift -o "$target"
"$target"

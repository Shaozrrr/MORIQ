#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${MORIQ_EXPERIMENTAL_SPEAKER:?}"
: "${MORIQ_WHISPER_HELPER:?}"
: "${MORIQ_WHISPER_MODEL:?}"
: "${MORIQ_SPEAKER_HELPER:?}"
: "${MORIQ_SPEAKER_MODEL:?}"
: "${MORIQ_SPEAKER_MINIMUM_COVERAGE:?}"
: "${MORIQ_SPEAKER_MAXIMUM_COMPETITION:?}"
: "${MORIQ_PUBLIC_SPEAKER_AUDIO:?}"
: "${MORIQ_TEST_FFMPEG:?}"
test_root="$(mktemp -d -t moriq-speaker-ui)"
trap 'rm -rf "$test_root"' EXIT
swiftc -DDEBUG -D MORIQ_SPEAKER_EXPERIMENTAL -suppress-warnings -parse-as-library MORIQ/LiveCaptions.swift MORIQ/LocalWhisperCaptions.swift MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift MORIQ/SpeakerDiarizationBridge.swift MORIQ/CaptionSpeakerAlignment.swift MORIQ/CaptionSpeakerNames.swift MORIQ/CaptionSpeakerPipeline.swift MORIQ/ExperimentalCaptionSpeakerAdapter.swift Tests/ManagedSpeech/TokenStub.swift Tests/ExperimentalCaptionSpeakerUI/main.swift -o "$test_root/test"
"$test_root/test"

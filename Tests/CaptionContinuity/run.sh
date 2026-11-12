#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_bin="$(mktemp -t moriq-caption-continuity)"
trap 'rm -f "$test_bin"' EXIT
swiftc MORIQ/LiveCaptions.swift MORIQ/LocalWhisperCaptions.swift MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift Tests/ManagedSpeech/TokenStub.swift Tests/CaptionContinuity/main.swift -o "$test_bin"
"$test_bin"

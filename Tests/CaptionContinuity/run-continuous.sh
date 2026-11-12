#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir="$(mktemp -d -t moriq-caption-continuous)"
trap 'rm -rf "$test_dir"' EXIT
sed 's/private struct LiveCaptionView: View/struct LiveCaptionView: View/' MORIQ/LiveCaptions.swift > "$test_dir/LiveCaptions.swift"
swiftc -parse-as-library "$test_dir/LiveCaptions.swift" MORIQ/LocalWhisperCaptions.swift MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift Tests/ManagedSpeech/TokenStub.swift Tests/CaptionContinuity/continuous.swift -o "$test_dir/test"
"$test_dir/test"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_root="$(mktemp -d -t moriq-caption-switch)"
trap 'rm -rf "$test_root"' EXIT
sed 's/private final class LiveCaptionAudioSink/final class LiveCaptionAudioSink/' MORIQ/LiveCaptions.swift > "$test_root/LiveCaptions.swift"
swiftc -suppress-warnings -parse-as-library "$test_root/LiveCaptions.swift" MORIQ/LocalWhisperCaptions.swift MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift Tests/ManagedSpeech/TokenStub.swift Tests/LiveCaptionsSourceSwitch/main.swift -o "$test_root/test"
/usr/bin/say -v Samantha -r 160 -o "$test_root/weather.aiff" 'The weather is sunny today. The weather is sunny today.'
MORIQ_SECOND_SYNTHETIC="$test_root/weather.aiff" "$test_root/test"

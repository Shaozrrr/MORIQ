#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_root="$(mktemp -d -t moriq-caption-presentation)"
trap 'rm -rf "$test_root"' EXIT
sed -e 's/private struct LiveCaptionView/struct LiveCaptionView/' MORIQ/LiveCaptions.swift > "$test_root/LiveCaptions.swift"
swiftc -D DEBUG -suppress-warnings -parse-as-library "$test_root/LiveCaptions.swift" MORIQ/CaptionWindowSizing.swift MORIQ/CaptionLanePages.swift MORIQ/CaptionSourceV2Reducer.swift MORIQ/LocalWhisperCaptions.swift MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift MORIQ/LocalDiagnostics.swift MORIQ/PermissionProbeState.swift MORIQ/RuntimeEnvironment.swift MORIQ/DeepSeek.swift MORIQ/DeviceRenewalCandidate.swift MORIQ/ManagedAIClient.swift Tests/CaptionDualPresentation/main.swift -o "$test_root/test"
"$test_root/test"

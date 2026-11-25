#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_bin="$(mktemp -t moriq-caption-continuity)"
trap 'rm -f "$test_bin"' EXIT
swiftc MORIQ/LiveCaptions.swift MORIQ/CaptionWindowSizing.swift MORIQ/CaptionLanePages.swift MORIQ/CaptionSourceV2Reducer.swift MORIQ/LocalWhisperCaptions.swift MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift MORIQ/LocalDiagnostics.swift MORIQ/PermissionProbeState.swift MORIQ/RuntimeEnvironment.swift MORIQ/DeepSeek.swift MORIQ/DeviceRenewalCandidate.swift MORIQ/ManagedAIClient.swift Tests/CaptionContinuity/main.swift -o "$test_bin"
"$test_bin"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
sed 's/private struct LiveCaptionView: View/struct LiveCaptionView: View/' MORIQ/LiveCaptions.swift > "$tmpdir/LiveCaptions.swift"
swiftc -parse-as-library "$tmpdir/LiveCaptions.swift" MORIQ/LocalWhisperCaptions.swift MORIQ/ManagedSpeechStream.swift MORIQ/ManagedSpeechAudioBridge.swift Tests/ManagedSpeech/TokenStub.swift Tests/LiveCaptionsTranslation/main.swift -o "$tmpdir/test"
"$tmpdir/test"

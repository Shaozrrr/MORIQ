#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BIN=$(mktemp -t moriq-managed-speech)
trap 'rm -f "$BIN"' EXIT
swiftc -DDEBUG -parse-as-library "$ROOT/MORIQ/ManagedSpeechStream.swift" "$ROOT/MORIQ/ManagedSpeechAudioBridge.swift" "$ROOT/Tests/ManagedSpeech/main.swift" -o "$BIN"
python3 "$ROOT/Tests/ManagedSpeech/test_network.py" "$BIN"

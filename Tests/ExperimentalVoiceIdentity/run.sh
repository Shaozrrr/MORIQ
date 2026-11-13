#!/bin/sh
set -eu
: "${MORIQ_FLUIDAUDIO_SOURCE:?Set the checkout of FluidAudio at the pinned commit}"
: "${MORIQ_CAMPLUS_MODEL:?Set the locally available CAM++ model directory}"
: "${MORIQ_PUBLIC_CLIPS:?Set the public alternating two-speaker WAV clip directory}"
: "${MORIQ_TEST_MATCH_THRESHOLD:?Set a test-only cosine threshold}"
: "${MORIQ_TEST_MARGIN:?Set a test-only minimum best-versus-second margin}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-identity-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$root/Tests/ExperimentalVoiceIdentity"
swift build -c release --scratch-path "$work/build"
"$work/build/release/VoiceIdentityCheck" "$MORIQ_CAMPLUS_MODEL" "$MORIQ_PUBLIC_CLIPS" "$MORIQ_TEST_MATCH_THRESHOLD" "$MORIQ_TEST_MARGIN"

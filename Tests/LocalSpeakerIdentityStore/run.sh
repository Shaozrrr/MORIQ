#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/moriq-identity.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
swiftc -parse-as-library "$root/MORIQ/LocalSpeakerIdentityStore.swift" "$root/Tests/LocalSpeakerIdentityStore/main.swift" -o "$tmp/check"
"$tmp/check"

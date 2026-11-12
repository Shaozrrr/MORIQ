#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo "usage: $0 OUTPUT_DIRECTORY" >&2; exit 2; fi
mkdir -p "$1"
phrase='The meeting starts at nine. Please review the project timeline. '
text=''
i=0
while [ "$i" -lt 20 ]; do text="$text$phrase"; i=$((i+1)); done
/usr/bin/say -v Samantha -r 180 -o "$1/english-20.aiff" "$text"
printf '%s\n' "$text" > "$1/english-20.reference.txt"
/usr/bin/afinfo "$1/english-20.aiff" | sed -n '/estimated duration/p'
printf '%s\n' 'Synthetic fixture only; no microphone or system audio is used.'

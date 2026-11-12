#!/bin/sh
# Build a fresh universal candidate without overwriting an existing file.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
src="$root/Vendor/MediaEngine/sources"
[ "$#" -eq 1 ] || { echo "Usage: build.sh /absolute/path/to/new-output" >&2; exit 2; }
case "$1" in /*) output=$1 ;; *) echo "Output must be absolute" >&2; exit 2 ;; esac
[ ! -e "$output" ] || { echo "Output already exists" >&2; exit 2; }
[ -d "$(dirname "$output")" ] || { echo "Output parent does not exist" >&2; exit 2; }
command -v pkgconf >/dev/null || { echo "pkgconf is required" >&2; exit 2; }
command -v nasm >/dev/null || { echo "nasm is required" >&2; exit 2; }
(cd "$root" && shasum -a 256 -c Vendor/MediaEngine/SHA256SUMS >/dev/null)
work=$(mktemp -d "${TMPDIR:-/tmp}/moriq-media-build.XXXXXX")
trap 'rm -r "$work"' EXIT HUP INT TERM
jobs=${MORIQ_BUILD_JOBS:-4}
case "$jobs" in ''|*[!0-9]*|0) echo "Invalid job count" >&2; exit 2 ;; esac
for arch in arm64 x86_64; do
  echo "Building $arch dependencies"
  base="$work/$arch"; prefix="$base/local"; mkdir -p "$base"
  for archive in "$src"/*.tar.gz; do tar -xzf "$archive" -C "$base"; done
  export MACOSX_DEPLOYMENT_TARGET=15.0 CC="clang -arch $arch" CXX="clang++ -arch $arch"
  if [ "$arch" = arm64 ]; then host=aarch64-apple-darwin; vpx=arm64-darwin24-gcc
  else host=x86_64-apple-darwin; vpx=x86_64-darwin24-gcc; fi
  (cd "$base/libvpx-1.17.0" && ./configure --target="$vpx" --disable-examples --disable-unit-tests --disable-tools --disable-docs --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/opus-1.5.2" && ./configure --host="$host" --disable-shared --enable-static --disable-extra-programs --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/libwebp-1.6.0" && ./configure --host="$host" --disable-shared --enable-static --disable-everything --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/lame-3.100" && ./configure --host="$host" --disable-shared --enable-static --disable-frontend --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/libogg-1.3.6" && ./configure --host="$host" --disable-shared --enable-static --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/libvorbis-1.3.7" && CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib" PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG="$(command -v pkgconf)" ./configure --host="$host" --disable-shared --enable-static --prefix="$prefix" && make -j"$jobs" CFLAGS="-O2 -arch $arch -I$prefix/include" && make install CFLAGS="-O2 -arch $arch -I$prefix/include")
  echo "Building $arch FFmpeg"
  (cd "$base/FFmpeg-n9.0.2"
    if [ "$arch" = x86_64 ]; then set -- --arch=x86_64 --target-os=darwin --enable-cross-compile --disable-x86asm; else set --; fi
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" ./configure "$@" --cc="clang -arch $arch" --disable-gpl --disable-nonfree --disable-doc --disable-ffplay --disable-ffprobe --disable-network --disable-debug --enable-videotoolbox --enable-libvpx --enable-libopus --enable-libwebp --enable-libmp3lame --enable-libvorbis --pkg-config="$(command -v pkgconf)" --pkg-config-flags=--static --extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib"
    make -j"$jobs" ffmpeg)
done
lipo -create "$work/arm64/FFmpeg-n9.0.2/ffmpeg" "$work/x86_64/FFmpeg-n9.0.2/ffmpeg" -output "$work/ffmpeg"
codesign --force --sign - "$work/ffmpeg"
codesign --verify --strict "$work/ffmpeg"
# Copy only after the complete candidate has passed structural checks.
install -m 755 "$work/ffmpeg" "$output"
printf 'Built %s\n' "$output"

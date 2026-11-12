#!/bin/bash
# Build a new candidate and retain its source, object code, static libraries,
# configuration and relink command. Never writes Vendor or an installed app.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
[[ $# == 1 && "$1" = /* ]] || { echo 'Usage: build_ffmpeg_materials.sh /absolute/path/to/new-directory' >&2; exit 2; }
out=$1
[[ ! -e "$out" && ! -L "$out" ]] || { echo 'Output already exists' >&2; exit 2; }
case "$out" in /Applications/*|"$HOME"/Applications/*|"$root"/*) echo 'Unsafe output path' >&2; exit 2;; esac
command -v pkgconf >/dev/null || { echo 'pkgconf is required' >&2; exit 2; }
command -v nasm >/dev/null || { echo 'nasm is required' >&2; exit 2; }
if [[ -d "$root/Vendor/MediaEngine/sources" ]]; then
  input="$root/Vendor/MediaEngine"
  (cd "$root" && shasum -a 256 -c Vendor/MediaEngine/SHA256SUMS >/dev/null)
  recipe="$root/Tools/Release/relink_ffmpeg_materials.py"
  verify="$root/Tools/Release/verify_ffmpeg_materials.py"
  override="$root/Tools/Release/verify_ffmpeg_override.py"
  manifest="$root/Tools/Release/create_ffmpeg_object_manifest.py"
  compare="$root/Tools/Release/compare_ffmpeg_capabilities.py"
  readme="$root/Tools/Release/FFMPEG_MATERIALS_README.md"
else
  input=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  (cd "$input" && shasum -a 256 -c metadata/source-sha256.txt >/dev/null)
  recipe="$input/relink.py"
  verify="$input/verify.py"
  override="$input/verify-modified-ogg.py"
  manifest="$input/create-object-manifest.py"
  compare="$input/compare-capabilities.py"
  readme="$input/README.md"
fi
mkdir -p "$out"/{sources,licenses,build,metadata}
touch "$out/INCOMPLETE"
cp "$input"/sources/*.tar.gz "$out/sources/"
cp "$input"/licenses/* "$out/licenses/"
if [[ -f "$input/SHA256SUMS" ]]; then cp "$input/SHA256SUMS" "$out/metadata/upstream-input-hashes.txt"; fi
if [[ -f "$input/README.md" ]]; then cp "$input/README.md" "$out/metadata/previous-build-notes.md"; fi
cp "$0" "$out/metadata/build-recipe.sh"
cp "$recipe" "$out/relink.py"
cp "$verify" "$out/verify.py"
cp "$override" "$out/verify-modified-ogg.py"
cp "$manifest" "$out/create-object-manifest.py"
cp "$compare" "$out/compare-capabilities.py"
cp "$readme" "$out/README.md"
(cd "$out" && shasum -a 256 sources/*.tar.gz > metadata/source-sha256.txt)
{ date -u; sw_vers; xcodebuild -version; clang --version; pkgconf --version; nasm -v; } > "$out/metadata/toolchain.txt"
jobs=${MORIQ_BUILD_JOBS:-4}
case "$jobs" in ''|*[!0-9]*|0) echo 'Invalid job count' >&2; exit 2;; esac
for arch in arm64 x86_64; do
  echo "Building $arch dependencies"
  base="$out/build/$arch"; prefix="$base/local"; mkdir -p "$base"
  for archive in "$out"/sources/*.tar.gz; do tar -xzf "$archive" -C "$base"; done
  export MACOSX_DEPLOYMENT_TARGET=15.0 CC="clang -arch $arch" CXX="clang++ -arch $arch"
  if [[ $arch == arm64 ]]; then host=aarch64-apple-darwin; vpx=arm64-darwin24-gcc
  else host=x86_64-apple-darwin; vpx=x86_64-darwin24-gcc; fi
  (cd "$base/libvpx-1.17.0" && ./configure --target="$vpx" --disable-examples --disable-unit-tests --disable-tools --disable-docs --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/opus-1.5.2" && ./configure --host="$host" --disable-shared --enable-static --disable-extra-programs --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/libwebp-1.6.0" && ./configure --host="$host" --disable-shared --enable-static --disable-everything --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/lame-3.100" && ./configure --host="$host" --disable-shared --enable-static --disable-frontend --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/libogg-1.3.6" && ./configure --host="$host" --disable-shared --enable-static --prefix="$prefix" && make -j"$jobs" && make install)
  (cd "$base/libvorbis-1.3.7" && CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib" PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG="$(command -v pkgconf)" ./configure --host="$host" --disable-shared --enable-static --prefix="$prefix" && make -j"$jobs" CFLAGS="-O2 -arch $arch -I$prefix/include" && make install CFLAGS="-O2 -arch $arch -I$prefix/include")
  echo "Building $arch FFmpeg"
  (cd "$base/FFmpeg-n9.0.2"
    if [[ $arch == x86_64 ]]; then set -- --arch=x86_64 --target-os=darwin --enable-cross-compile --disable-x86asm; else set --; fi
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" ./configure "$@" --cc="clang -arch $arch" --disable-gpl --disable-nonfree --disable-doc --disable-ffplay --disable-ffprobe --disable-network --disable-debug --enable-videotoolbox --enable-libvpx --enable-libopus --enable-libwebp --enable-libmp3lame --enable-libvorbis --pkg-config="$(command -v pkgconf)" --pkg-config-flags=--static --extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib"
    make -j"$jobs" V=1 ffmpeg
    make -n -W fftools/ffmpeg.o ffmpeg_g | tail -1 > "$out/metadata/link-$arch.txt"
    cp ffbuild/config.mak "$out/metadata/config-$arch.mak"
    cp ffbuild/config.log "$out/metadata/config-$arch.log"
  )
done
lipo -create "$out/build/arm64/FFmpeg-n9.0.2/ffmpeg" "$out/build/x86_64/FFmpeg-n9.0.2/ffmpeg" -output "$out/ffmpeg"
codesign --force --sign - "$out/ffmpeg"
codesign --verify --strict "$out/ffmpeg"
(cd "$out" && shasum -a 256 ffmpeg > metadata/candidate-sha256.txt)
rm "$out/INCOMPLETE"
touch "$out/COMPLETE"
if ! python3 "$out/create-object-manifest.py" "$out"; then
  mv "$out/COMPLETE" "$out/INCOMPLETE"
  exit 1
fi
echo "Built independent candidate and materials: $out"
echo 'Not installed, signed for distribution, notarized or legally approved.'

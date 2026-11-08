#!/bin/sh
# Build the static armv7 aruntime: the AppImage runtime that needs no FUSE, no
# mount, no user namespaces and no host libc, so the image runs on musl distros,
# old glibc distros, Termux and the Android adb shell alike.
#
#   ./aruntime-build.sh <zlib-source-dir> [output]

set -eu

ZLIB=${1:?usage: $0 <zlib-source-dir> [output]}
OUT=${2:-$(cd -- "$(dirname -- "$0")" && pwd)/bin/aruntime-armv7}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ -f "$ZLIB/libz.a" ] || { echo "error: no static libz.a in $ZLIB" >&2; exit 1; }
mkdir -p "$(dirname -- "$OUT")"

# -mcpu=cortex_a8-neon is the armv7-a + VFPv3-D16 + no-NEON baseline; zig's
# default target CPU for arm-linux-musleabihf pulls NEON in.
zig cc -target arm-linux-musleabihf -mcpu=cortex_a8-neon -Os -static \
	-I "$ZLIB" -o "$OUT" "$HERE/../src/aruntime.c" "$ZLIB/libz.a"

echo "built: $OUT"

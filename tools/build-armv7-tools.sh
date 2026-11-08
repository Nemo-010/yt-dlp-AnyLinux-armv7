#!/bin/sh
# Builds the three armv7 tools this repository needs and upstream has no build
# for. Everything lands in tools/bin/ (gitignored).
#
#   aruntime   static AppImage runtime: reads the appended squashfs itself and
#              extracts it. No FUSE, no mount, no namespaces, no host libc.
#   dash       static shell, because sharun runs AppRun.sh with the dash that
#              sits next to it and Android's shell is /system/bin/sh.
#   sharun     Anylinux-sharun patched for armv7 (see patches/), used as AppRun.
#
# Sources are pinned; patches are applied against the pinned commits.

set -eu

ARCH=armv7
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
WORK=${WORK:-$ROOT/build}
BIN=$HERE/bin

ZLIB_VERSION=1.3.1
DASH_VERSION=0.5.13.5
SHARUN_REF=2748a37bfaad6c379cb2ca124e84d14eab6ba3d9
USERLAND_EXECVE_REF=d2b58d8b5164b8c815c3f504eb3ddfff47f31556

mkdir -p "$WORK" "$BIN"

# zig is the cross compiler for every armv7 object here: one toolchain, no
# cross gcc, and -mcpu=cortex_a8-neon keeps the FP baseline at VFPv3/no NEON.
command -v zig >/dev/null 2>&1 || { echo "error: zig not found (run get-dependencies.sh)" >&2; exit 1; }
printf '#!/bin/sh\nexec zig cc -target arm-linux-musleabihf -mcpu=cortex_a8-neon "$@"\n' > "$WORK/zigcc-armv7"
chmod +x "$WORK/zigcc-armv7"

echo "== zlib $ZLIB_VERSION (static, armv7)"
if [ ! -f "$WORK/zlib/libz.a" ]; then
	curl -sfL -o "$WORK/zlib.tar.gz" \
		"https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz"
	mkdir -p "$WORK/zlib" && tar xzf "$WORK/zlib.tar.gz" --strip-components=1 -C "$WORK/zlib"
	(cd "$WORK/zlib" && CC="$WORK/zigcc-armv7" CFLAGS=-Os ./configure --static >/dev/null && make -j"$(nproc)" libz.a >/dev/null)
fi
echo "  ok"

echo "== aruntime"
sh "$HERE/aruntime-build.sh" "$WORK/zlib" "$BIN/aruntime-armv7"

echo "== dash $DASH_VERSION (static, armv7)"
if [ ! -f "$WORK/dash/src/dash" ]; then
	curl -sfL -o "$WORK/dash.tar.gz" \
		"https://distfiles.alpinelinux.org/distfiles/edge/dash-$DASH_VERSION.tar.gz"
	mkdir -p "$WORK/dash" && tar xzf "$WORK/dash.tar.gz" --strip-components=1 -C "$WORK/dash"
	(cd "$WORK/dash" && CC="$WORK/zigcc-armv7" CFLAGS=-Os ./configure \
		--host=arm-linux-musleabihf --enable-static >/dev/null && make -j"$(nproc)" LDFLAGS=-s >/dev/null)
fi
cp "$WORK/dash/src/dash" "$BIN/dash-armv7"
chmod +x "$BIN/dash-armv7"
echo "  ok"

echo "== userland-execve-rust @ $USERLAND_EXECVE_REF"
if [ ! -d "$WORK/userland-execve-rust" ]; then
	git clone -q https://github.com/pkgforge-dev/userland-execve-rust "$WORK/userland-execve-rust"
	git -C "$WORK/userland-execve-rust" checkout -q "$USERLAND_EXECVE_REF"
	git -C "$WORK/userland-execve-rust" apply "$ROOT/patches/userland-execve-rust-armv7.patch"
fi
echo "  ok"

echo "== sharun @ $SHARUN_REF"
if [ ! -d "$WORK/sharun" ]; then
	git clone -q https://github.com/pkgforge-dev/Anylinux-sharun "$WORK/sharun"
	git -C "$WORK/sharun" checkout -q "$SHARUN_REF"
	git -C "$WORK/sharun" apply "$ROOT/patches/sharun-armv7.patch"
	# the patch touches sources only; the armv7 build settings are appended here
	# so the patch stays independent of where the build happens
	cat >> "$WORK/sharun/.cargo/config.toml" <<-EOF

	[target.armv7-unknown-linux-musleabihf]
	linker = "$WORK/zigcc-armv7"
	rustflags = ["-C", "link-self-contained=no"]

	[patch."https://github.com/pkgforge-dev/userland-execve-rust"]
	userland-execve = { path = "$WORK/userland-execve-rust" }
	EOF
fi
(cd "$WORK/sharun" && cargo build --release --target armv7-unknown-linux-musleabihf >/dev/null 2>&1) \
	|| { echo "error: sharun build failed (needs the pinned nightly + rust-src, see get-dependencies.sh)" >&2; exit 1; }
cp "$WORK/sharun/target/armv7-unknown-linux-musleabihf/release/sharun" "$BIN/sharun-armv7"
chmod +x "$BIN/sharun-armv7"
echo "  ok"

echo
printf 'built into %s:\n' "$BIN"
for f in "$BIN"/*; do printf '  %-16s %8d bytes\n' "$(basename "$f")" "$(wc -c < "$f")"; done

#!/bin/sh
# Builds yt-dlp as a single-file armv7 AppImage.
#
# Anylinux normally does this with quick-sharun + sharun + uruntime. None of
# those three has an armv7 build, so this repository carries its own equivalents
# in tools/ and patches/ and drives them in the same order:
#
#   deploy closure   tools/alpine-armv7-fetch.py (packages) + AppDir assembly
#   AppRun           tools/bin/sharun-armv7  (patched Anylinux-sharun)
#   pack             tools/bin/aruntime-armv7 + mksquashfs (gzip, no fragments)
#
# Deliberate deviations from the usual Anylinux flow, each for a reason:
#   - the runtime is aruntime, not uruntime: no armv7 build of uruntime exists,
#     and uruntime needs FUSE + user namespaces, which Android does not grant
#   - squashfs is gzip only: that is what aruntime can read today
#   - no .upd_info/zsync: appimagetool has no armv7 build and aruntime does not
#     implement self-updates, so claiming update support would be a lie

set -eu

ARCH=armv7
NAME=yt-dlp
export ARCH
export OUTPATH=${OUTPATH:-$PWD/dist}
WORK=${WORK:-$PWD/build}

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/tools/bin

rm -rf "$OUTPATH" "$WORK/AppDir"
mkdir -p "$OUTPATH" "$WORK" "$WORK/sysroot"

echo "Building the armv7 tools..."
echo "---------------------------------------------------------------"
sh "$HERE/tools/build-armv7-tools.sh"

echo "Fetching the payload from Alpine edge ($ARCH)..."
echo "---------------------------------------------------------------"
# Alpine edge armv7 is musl, so the payload needs no glibc at all: no glibc
# version floor, no glibc resolver behaviour, and half the bytes of the glibc
# route. yt-dlp-core carries the code; python3 carries the interpreter.
python3 "$HERE/tools/alpine-armv7-fetch.py" "$WORK/sysroot" yt-dlp-core ca-certificates-bundle

VERSION=$(sed -n "s/^__version__ *= *'\(.*\)'.*/\1/p" \
	"$WORK/sysroot/usr/lib/python3.14/site-packages/yt_dlp/version.py" | head -n 1)
[ -n "$VERSION" ] || { echo "error: could not read the yt-dlp version" >&2; exit 1; }
echo "  yt-dlp $VERSION"

echo "Assembling the AppDir..."
echo "---------------------------------------------------------------"
APPDIR=$WORK/AppDir
mkdir -p "$APPDIR/bin" "$APPDIR/.bin" "$APPDIR/lib" "$APPDIR/share/lib" "$APPDIR/share/ca"

# the interpreter and the entry script
cp "$WORK/sysroot/usr/bin/python3.14" "$APPDIR/.bin/python3"
cp "$WORK/sysroot/usr/bin/python3.14" "$APPDIR/.bin/python3.14"
cp "$WORK/sysroot/usr/bin/yt-dlp"     "$APPDIR/.bin/yt_dlp_script.py"
chmod +x "$APPDIR/.bin/python3" "$APPDIR/.bin/python3.14" "$APPDIR/.bin/yt_dlp_script.py"

# loader + the interpreter's shared libraries
cp -a "$WORK/sysroot/lib/." "$APPDIR/lib/"
cp -a "$WORK/sysroot/usr/lib/"*.so* "$APPDIR/lib/" 2>/dev/null || :
# lib-dynload opens these at runtime rather than linking them
for lib in libssl.so.3 libcrypto.so.3 libsqlite3.so.3 libffi.so.8 libbz2.so.1 \
	liblzma.so.5 libz.so.1 libexpat.so.1 libncursesw.so.6 libpanelw.so.6 \
	libreadline.so.8 libmpdec.so.4 libgcc_s.so.1; do
	[ -e "$APPDIR/lib/$lib" ] || cp -a "$WORK/sysroot/usr/lib/$lib"* "$APPDIR/lib/" 2>/dev/null || :
done

# python's standard library and the yt_dlp package
cp -a "$WORK/sysroot/usr/lib/python3.14" "$APPDIR/share/lib/"

# trust store, bundled so TLS never depends on the host
for cert in etc/ssl/certs/ca-certificates.crt etc/ssl/cert.pem; do
	[ -f "$WORK/sysroot/$cert" ] && cp "$WORK/sysroot/$cert" "$APPDIR/share/ca/" || :
done
[ -f "$APPDIR/share/ca/ca-certificates.crt" ] || {
	echo "error: no CA bundle was fetched" >&2; exit 1; }

# AppRun is sharun; bin/<name> is a hardlink to it, as Anylinux does
cp "$BIN/sharun-armv7" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
ln -f "$APPDIR/AppRun" "$APPDIR/bin/$NAME"

# static shell for AppRun.sh, so the image needs no /bin/sh from the host
cp "$BIN/dash-armv7" "$APPDIR/dash"

cp "$HERE/AppDir/AppRun.sh"      "$APPDIR/AppRun.sh"
sed "s/@VERSION@/$VERSION/" "$HERE/AppDir/$NAME.desktop" > "$APPDIR/$NAME.desktop"
chmod +x "$APPDIR/AppRun.sh"

echo "Packing..."
echo "---------------------------------------------------------------"
# gzip + no fragments: what aruntime reads. zstd would be smaller but the
# runtime has no zstd yet.
mksquashfs "$APPDIR" "$WORK/$NAME.squashfs" \
	-comp gzip -no-fragments -noappend -all-root -no-xattrs -quiet >/dev/null

APPIMAGE=$OUTPATH/$NAME-$ARCH.AppImage
cat "$BIN/aruntime-armv7" "$WORK/$NAME.squashfs" > "$APPIMAGE"
chmod +x "$APPIMAGE"

echo "$VERSION" > "$OUTPATH/version"

# pkgforge-dev/make-stable-appimage-release reads this; appimagetool would
# normally write it, and we do not have an armv7 appimagetool.
cat > "$OUTPATH/appinfo" <<EOF
X-AppImage-Name=$NAME
X-AppImage-Version=$VERSION
X-AppImage-Arch=$ARCH
EOF

echo "Checking..."
echo "---------------------------------------------------------------"
sh "$HERE/tools/armv7-portability-check.sh" \
	"$APPIMAGE" "$BIN/aruntime-armv7" "$BIN/dash-armv7"

echo
printf '%s\n' "  $APPIMAGE"
printf '  %-28s %10s bytes\n' "$(basename "$APPIMAGE")" "$(wc -c < "$APPIMAGE")"

# An extra archive, because the AppImage is a touch too large for some upload
# limits and 7z on an already-gzipped squashfs is the best that can be done
# without a second compressor in the runtime.
if command -v 7z >/dev/null 2>&1; then
	7z a -bso0 -bsp0 -m0=ARM -m1=LZMA2:lc=0:pb=2:mf=bt4 -mx=9 \
		"$APPIMAGE.7z" "$APPIMAGE" >/dev/null
	printf '  %-28s %10s bytes\n' "$(basename "$APPIMAGE").7z" "$(wc -c < "$APPIMAGE.7z")"
fi

echo
echo "Test it with ./tools/smoke-test.sh $APPIMAGE"

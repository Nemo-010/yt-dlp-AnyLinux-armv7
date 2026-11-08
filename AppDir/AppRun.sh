#!/bin/sh
# Runs inside the AppImage: started by sharun with APPDIR already set.
#
# Everything the payload needs comes from the AppImage: the interpreter, its
# modules, the CA bundle, the loader. Only the kernel is taken from the host.
# That is what makes this work on musl distros, old glibc distros, Termux and
# the Android adb shell, none of which can be relied on to provide any of it.

export PYTHONHOME="$APPDIR/share"
export PYTHONPATH="$APPDIR/share/lib/python3.14:$APPDIR/share/lib/python3.14/site-packages"

# TLS: yt-dlp must not fall back to whatever trust store the host may or may not
# have (Android keeps its own, in a format musl cannot read).
export SSL_CERT_FILE="$APPDIR/share/ca/ca-certificates.crt"
export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"

# Android has no /tmp and Termux may leave TMPDIR pointing nowhere.
export TMPDIR="${TMPDIR:-${HOME:-/tmp}/tmp}"
[ -d "$TMPDIR" ] || mkdir -p "$TMPDIR" 2>/dev/null || :

exec "$APPDIR/lib/ld-musl-armhf.so.1" --library-path "$APPDIR/lib" \
	"$APPDIR/.bin/python3" "$APPDIR/.bin/yt_dlp_script.py" "$@"

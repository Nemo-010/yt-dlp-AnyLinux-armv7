#!/bin/sh
# Smoke test for the armv7 AppImage.
#
# qemu-user cannot execve an armv7 binary from inside an emulated process (no
# binfmt_misc outside it), so the one step CI cannot walk is the runtime exec'ing
# AppRun. Everything around it is checked here for real:
#
#   1. the runtime runs, finds the squashfs and extracts it completely
#   2. the extracted payload runs through the bundled loader and reports the
#      version the build was supposed to produce
#   3. AppRun.sh parses with the bundled dash
#
# Set YTDLP_NETWORK_TEST=1 to also do a TLS request with the bundled CA bundle.

set -eu

IMAGE=${1:?usage: $0 <path-to-AppImage>}
VERSION_FILE=${2:-$(dirname -- "$IMAGE")/version}
QEMU=${QEMU:-qemu-arm-static}
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=1; }

say "== $IMAGE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

command -v "$QEMU" >/dev/null 2>&1 || { bad "no $QEMU"; exit 1; }
# GitHub artifact and release downloads strip the exec bit; say so rather than
# reporting an empty extraction
[ -x "$IMAGE" ] || { bad "not executable: $IMAGE (chmod +x it)"; exit 1; }

# 1. run the runtime; the exec of AppRun is expected to fail under qemu, the
#    extraction is not
mkdir -p "$TMP/cache"
TMPDIR=$TMP/cache "$QEMU" "$IMAGE" --version >"$TMP/out" 2>"$TMP/err" || :

ROOT=$(find "$TMP/cache" -maxdepth 1 -name '.aruntime-*' -type d 2>/dev/null | head -n 1)
[ -n "$ROOT" ] && ok "runtime found the squashfs and extracted" || bad "runtime did not extract anything"
[ -n "$ROOT" ] || { say "--- stderr:"; sed 's/^/    /' "$TMP/err"; exit 1; }
[ -f "$ROOT/.complete" ] && ok "extraction marked complete" || bad "extraction did not finish"

for f in AppRun AppRun.sh bin/yt-dlp dash lib/ld-musl-armhf.so.1 .bin/python3 \
	share/lib/python3.14/site-packages/yt_dlp share/ca/ca-certificates.crt; do
	[ -e "$ROOT/$f" ] && ok "present: $f" || bad "missing: $f"
done

# 2. the payload itself
LOADER=$ROOT/lib/ld-musl-armhf.so.1
got=$(PYTHONHOME=$ROOT/share "$QEMU" "$LOADER" --library-path "$ROOT/lib" \
	"$ROOT/.bin/python3" -c 'import yt_dlp; print(yt_dlp.version.__version__)' 2>"$TMP/pyerr" || true)

if [ -n "$got" ]; then
	ok "payload runs through the bundled loader (yt_dlp $got)"
else
	bad "payload did not run"
	sed 's/^/    /' "$TMP/pyerr"
fi

if [ -f "$VERSION_FILE" ]; then
	want=$(cat "$VERSION_FILE")
	[ "$got" = "$want" ] && ok "version matches the build ($want)" || bad "version mismatch: got '$got' want '$want'"
else
	say "  note  no version file at $VERSION_FILE, skipping the comparison"
fi

cli=$(PYTHONHOME=$ROOT/share "$QEMU" "$LOADER" --library-path "$ROOT/lib" \
	"$ROOT/.bin/python3" "$ROOT/.bin/yt_dlp_script.py" --version 2>/dev/null || true)
[ "$cli" = "$got" ] && ok "--version agrees ($cli)" || bad "--version said '$cli'"

# 3. the shell entry point
"$QEMU" "$ROOT/dash" -n "$ROOT/AppRun.sh" 2>"$TMP/sherr" \
	&& ok "AppRun.sh parses with the bundled dash" \
	|| { bad "AppRun.sh does not parse"; sed 's/^/    /' "$TMP/sherr"; }

# 4. optional live TLS check. Informational by default: a DNS or upstream outage
#    must not turn a good build red. Set YTDLP_NETWORK_TEST_STRICT=1 to gate on it.
if [ "${YTDLP_NETWORK_TEST-}" = 1 ]; then
	if PYTHONHOME=$ROOT/share SSL_CERT_FILE=$ROOT/share/ca/ca-certificates.crt \
		"$QEMU" "$LOADER" --library-path "$ROOT/lib" "$ROOT/.bin/python3" -c '
import json, ssl, urllib.request
ctx = ssl.create_default_context()
r = urllib.request.urlopen("https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest", context=ctx, timeout=30)
print(json.load(r)["tag_name"])' >"$TMP/net" 2>"$TMP/neterr"; then
		ok "live TLS with the bundled CA (latest upstream: $(cat "$TMP/net"))"
	elif [ "${YTDLP_NETWORK_TEST_STRICT-}" = 1 ]; then
		bad "live TLS failed"
		sed 's/^/    /' "$TMP/neterr"
	else
		say "  warn  live TLS failed (not fatal; set YTDLP_NETWORK_TEST_STRICT=1 to gate)"
		sed 's/^/    /' "$TMP/neterr"
	fi
fi

say
[ "$FAIL" = 0 ] && say "smoke test passed" || say "smoke test FAILED"
exit "$FAIL"
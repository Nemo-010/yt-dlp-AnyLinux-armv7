#!/bin/sh
# armv7-portability-check.sh <binary>...
# Checks whether an armv7 ELF can claim "runs on any armv7 Linux".
# POSIX sh, needs readelf and strings only.

FAIL=0
BASE_FP='VFPv3'   # VFPv3-D16 is the ARMv7 floor; VFPv4 uses vfma, absent on A8/A9

bad() { printf '  FAIL  %s\n' "$*"; FAIL=1; }
ok()  { printf '  ok    %s\n' "$*"; }

for bin in "$@"; do
	printf '%s\n' "== $bin"

	# 1. shape: 32-bit ARM, EABI5, hard-float
	hdr=$(readelf -h "$bin" 2>/dev/null)
	printf '%s' "$hdr" | grep -q 'Machine:.*ARM' \
		&& ok 'ELF machine is ARM' || bad 'not an ARM ELF'
	printf '%s' "$hdr" | grep -q 'Class:.*ELF32' \
		&& ok 'ELF32' || bad 'not ELF32'
	printf '%s' "$hdr" | grep -q 'Version5 EABI' \
		&& ok 'EABI5' || bad 'not EABI version 5'
	printf '%s' "$hdr" | grep -q 'hard-float ABI' \
		&& ok 'hard-float ABI' || bad 'not hard-float (armel/softfloat)'
	printf '%s' "$hdr" | grep -qE 'Version4 EABI' && bad 'EABI4 (pre-armhf)'

	# 2. self-containment: no interpreter, no dynamic section, no NEEDED
	readelf -l "$bin" 2>/dev/null | grep -q INTERP && bad 'has PT_INTERP (needs a host loader)' || ok 'no PT_INTERP'
	readelf -d "$bin" 2>/dev/null | grep -q NEEDED && bad 'has DT_NEEDED (needs host libraries)' || ok 'no DT_NEEDED'
	readelf -d "$bin" 2>/dev/null | grep -qE 'RPATH|RUNPATH' && bad 'has RPATH/RUNPATH' || :

	# 3. instruction baseline from .ARM.attributes
	attr=$(readelf -A "$bin" 2>/dev/null)
	if [ -n "$attr" ]; then
		printf '%s' "$attr" | grep -qE 'Tag_CPU_arch: v7' \
			&& ok 'CPU arch v7' || bad "$(printf '%s' "$attr" | grep -m1 Tag_CPU_arch)"
		fp=$(printf '%s' "$attr" | grep -m1 'Tag_FP_arch' | sed 's/.*: //')
		case "$fp" in
			"$BASE_FP"*) ok "FP arch $fp" ;;
			"VFPv3-D16"|"VFPv3") ok "FP arch $fp" ;;
			*) bad "FP arch '$fp' above the ARMv7 baseline (vfp needs vfma on A8/A9)" ;;
		esac
		if printf '%s' "$attr" | grep -q 'Tag_Advanced_SIMD_arch'; then
			bad "$(printf '%s' "$attr" | grep -m1 'Tag_Advanced_SIMD_arch' | sed 's/^ *//') -- requires NEON"
		else
			ok 'no NEON'
		fi
		printf '%s' "$attr" | grep -q 'Tag_CPU_name: "cortex-a7"' && \
			printf '  note  cpu_name cortex-a7 (harmless, but check FP above)\n'
	else
		printf '  note  no .ARM.attributes section, cannot judge the instruction set\n'
	fi

	# 4. environment assumptions a CLI binary silently inherits
	for p in /etc/passwd /etc/resolv.conf /etc/ssl/certs /usr/share/terminfo /usr/share/zoneinfo; do
		if strings -a "$bin" | grep -qxF "$p" || strings -a "$bin" | grep -qF "$p/"; then
			printf '  note  references %s (absent on Android and on musl hosts)\n' "$p"
		fi
	done
	strings -a "$bin" | grep -qE '/lib/ld-|/lib/ld-musl-' && bad 'hardcoded loader path in strings' || :

	# 5. no glibc symbol versions, no dlopen of host libraries
	strings -a "$bin" | grep -q 'GLIBC_2\.' && bad 'references GLIBC_ symbol versions' || ok 'no GLIBC_ symbols'
done

[ "$FAIL" = 0 ] && printf '\nAll checked binaries pass the armv7 baseline.\n' \
	|| printf '\nAt least one binary cannot claim "any armv7 Linux".\n'
exit "$FAIL"

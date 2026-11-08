# "Runs on any armv7 Linux" — CLI-only portability notes

Scope: command-line applications only, no GUI. Target: one artifact that runs on
armv7 Linux everywhere — Debian/Raspbian armhf, Ubuntu armhf, Arch ARM armv7h,
Alpine, postmarketOS, OpenWrt, a chroot, Termux on armv7 Android, and the adb
shell on the same phone.

Everything marked **verified** below was measured in this session with
zig 0.17, rust 1.99, and `qemu-arm-static` 7.2 (host kernel 7.2; the ARM kernel
floor is argued from musl's source, not measured).

Companion file: `armv7-portable-notes.md` holds the wider picture (GUI apps, the
missing sharun/uruntime/onelf armv7 builds, why the AppImage shape is out of
scope for CLI).

Scripts: `armv7-portability-check.sh` (does a binary really claim "any armv7
Linux"?) and `armv7-anywrap.sh` (turn an *existing* dynamic armv7 ELF into a
bundle with its own loader and glibc; tested in §10).

---

## 1. The structural insight: for a static CLI there is no bundle

The desktop AppImage/onelf shape exists to solve three problems: carry a libc,
carry a loader, and hand the payload a filesystem. A **statically linked musl
binary has none of those problems**:

| Problem the AppImage solves | Static musl CLI |
|---|---|
| host glibc too old / musl host | no libc dependency at all |
| loader path differs per distro | no `PT_INTERP`, nothing to interpret |
| payload needs a filesystem tree | one file, no tree |
| needs FUSE + namespaces | needs neither (`/dev/fuse` is often absent on OpenWrt, blocked on Android) |
| 200–400 MB image | **20 KB–2 MB** |

So "AnyLinux for armv7 CLI" is not an AppImage minus the GUI. It is a
*compile-time contract plus a small environment shim*, and the interesting part
moves from "how do I carry a loader" to **"which files does libc insist on
reading that the host may not have"**.

Measured, for scale: a C hello-world-with-uname/probe is **20 KB** static musl;
a Rust binary using `std` and `libc` is **344 KB**. Both run on an x86_64 host
under `qemu-arm-static` with no ARM userland present.

---

## 2. Verified: the CPU baseline is a build-flag landmine

`readelf -A` on three builds of the same C file, all `-target arm-linux-musleabihf`:

| build | `Tag_FP_arch` | `Tag_Advanced_SIMD_arch` | verdict |
|---|---|---|---|
| `zig cc` **default** | VFPv3 | **NEONv1** | dies on non-NEON ARMv7 |
| `-mcpu=cortex_a7` | **VFPv4** | NEONv1 with Fused-MAC | needs `vfma` → A7/A15 only |
| `-mcpu=cortex_a8-neon` | VFPv3 | — | **the baseline** |

Two traps, both silent:

1. **zig's default target CPU for `arm-linux-musleabihf` enables NEON.** Even a
   trivial `zig cc -target arm-linux-musleabihf` object carries
   `Tag_Advanced_SIMD_arch: NEONv1`. Non-NEON ARMv7 exists in the field (Tegra 2,
   Marvell Armada 370/XP, some Allwinner/TI parts), and NEON here is not
   negotiated at runtime — it is a SIGILL.
2. **`-mcpu=cortex_a7` is not a safe default** either: A7/A15 advertise VFPv4,
   and `vfma` faults on Cortex-A8/A9. The ARMv7 floor is `armv7-a + VFPv3-D16`,
   no NEON, hard float.

Rust hits the same thing from a different direction: `armv7-unknown-linux-musleabihf`
is a normal static target, but the final binary's float/NEON attributes are set
by *everything* linked in, and the linker is what zig cc is. Cross-building
worked with this, no ARM gcc anywhere:

```toml
# .cargo/config.toml
[target.armv7-unknown-linux-musleabihf]
linker = "/path/to/zigcc"          # exec zig cc -target arm-linux-musleabihf -mcpu=cortex_a8-neon "$@"
rustflags = ["-C", "link-self-contained=no"]   # else zig and rust-src musl crt both define _start
```

Without `-mcpu` on the `zig cc` wrapper the resulting Rust binary carries
`NEONv1` again, and without `link-self-contained=no` the link fails with
`duplicate symbol: _start`. Both were reproduced here; with both fixed the
binary reports `Tag_FP_arch: VFPv3`, no SIMD tag, and runs.

---

## 3. Verified: musl's 64-bit `time_t` still runs on old kernels, Rust's does not

`sizeof` printout from the same probe, run under qemu:

| toolchain | `time_t` | `off_t` | `ino_t` |
|---|---|---|---|
| C, zig cc + musl | **8** | 8 | 8 |
| Rust `armv7-unknown-linux-musleabihf` | **4** | 8 | — |

- musl 1.2.4+ gives 32-bit ARM a 64-bit `time_t`. That normally implies kernel
  5.1+ (`clock_gettime64`, `futex_time64`), which would exclude every armv7
  vendor kernel in existence — **but musl falls back**. `src/time/clock_gettime.c`
  tries `clock_gettime64`, and on `ENOSYS` falls back to `clock_gettime`, then to
  `gettimeofday`; `src/thread/__timedwait.c` only reaches for `futex_time64` when
  the value does not fit in 32 bits, else `futex`. A `qemu -strace` run confirms
  the binary asks for `clock_gettime64(CLOCK_REALTIME)` first. Practical floor:
  the normal 32-bit syscalls, i.e. anything from ~2.6.16 up, with the 2038 cliff
  only for values that overflow.
- Rust's armv7 targets have **no** time64 support: `time_t` is 4 bytes, so a
  Rust CLI on armv7 is 2038-broken by construction (fine today, but it is a
  real difference from the C route).
- Therefore: **C/musl is the better carrier for the baseline profile; Rust is
  fine and much nicer for anything with TLS/JSON, with the 2038 caveat written
  down.**

---

## 4. Verified: the one host file a bundle cannot redirect — `resolv.conf`

`src/network/resolvconf.c` opens the literal path `"/etc/resolv.conf"`. There is
no `RESOLV_CONF` environment variable, no `--sysconfdir` at build time, no env
override at runtime (unlike glibc, where `RES_OPTIONS`/`LOCALDOMAIN` at least
exist). Consequences for "any armv7 Linux":

- musl hosts and most distros: file present, DNS works.
- **Android/Termux: there is no `/etc/resolv.conf`.** Bionic does not read one —
  it asks netd over a socket. A *static musl or static Go* binary therefore has
  no resolver on Android unless something provides the file (Termux's
  `termux-chroot` does, via proot; a bare `adb shell` does not).
- Options, in order of honesty: (a) implement DNS in the application
  (Rust `hickory`, or a tiny UDP stub honouring a `DNS` env var), (b) document
  `proot`/`termux-chroot` as a prerequisite on Android, (c) post-build patch of
  the `/etc/resolv.conf` literal inside the static binary to a shorter path you
  control (the string is 18 bytes with the NUL, so `/tmp/resolv.conf` fits —
  but `/tmp` does not exist on Android either, so this is a distro-only trick).

Same class of problem, smaller blast radius: `getpwnam` reads `/etc/passwd`
(absent on Android, so uid→name lookups fail), `/etc/hosts` for `localhost`,
`/etc/services`.

---

## 5. The environment contract (what "any armv7 Linux" actually requires)

A CLI binary is portable when it only needs the kernel; a *useful* CLI binary
also needs these, and each can be made to come from the artifact itself:

| Need | Host has it? | Fix inside the artifact |
|---|---|---|
| libc, loader | varies | static musl (verified: no `PT_INTERP`, no `DT_NEEDED`) |
| CPU/FP baseline | varies | build flags (§2); hard-float, armv7-a, VFPv3-D16, no NEON |
| kernel ABI | ≥ 3.x typical | avoid `statx`/`clone3`-only paths, or accept musl's fallbacks |
| CA trust store | `/etc/ssl/certs`, Android `/system/etc/security/cacerts`, Termux `$PREFIX/etc/tls/cert.pem` | embed roots: `rustls` + `webpki-roots` compiles them in; OpenSSL/GnuTLS builds honour `SSL_CERT_FILE`/`CURL_CA_BUNDLE` pointing at an extracted copy |
| terminfo | often absent on Android and minimal images | embed the few entries you use and set `TERMINFO`; avoids "Error opening terminal: xterm-256color" |
| `TMPDIR`/`/tmp` | **no `/tmp` on Android** | default TMPDIR to `$HOME/tmp` or a directory beside the binary |
| `TZ`/zoneinfo | Android `/system/usr/share/zoneinfo`, musl minimal images nothing | embed tzdata (`TZDIR`) or accept UTC |
| `/bin/sh` | Android is `/system/bin/sh` | do not shell out; if unavoidable, probe `sh` on `PATH` |
| user names | `/etc/passwd` absent on Android | degrade gracefully (show numeric uid) |
| DNS | see §4 | in-app resolver or documented proot |

That table *is* the armv7 counterpart of sharun's job: where sharun owns the
loader, a CLI artifact owns the environment.

---

## 6. Verified: one file can carry its own environment

A static ELF plus an appended payload, located through `/proc/self/exe` at a
fixed offset (footer: magic + offset + length), works on armv7:

```
$ ls -l blob blob.bin
-rwxr-xr-x 1 ... 24396 blob            # plain binary
-rwxr-xr-x 1 ... 24473 blob.bin        # same + 57-byte payload appended
$ qemu-arm-static ./blob.bin
blob at 24396, 57 bytes: ca-bundle: 1 cert
terminfo: xterm-256color
zoneinfo: UTC
```

No FUSE, no mount, no extraction, no second file, no squashfs, no runtime — the
whole AppImage machinery replaced by an `fseek`. `/proc/self/exe` is present on
Android and every mainstream kernel; the fallback is `argv[0]`.

Two ways to use that slot, depending on size:

- **small data** (a few terminfo entries, a zone or two, a public-suffix list):
  just link it in with `objcopy --input binary` / `include_bytes!` — no carrier
  at all;
- **larger data** (a CA bundle, core tzdata, a man-page set, ffmpeg
  presets/`mpv` scripts): the appended blob, read lazily. Data stays in the
  page cache and can be streamed; nothing is written to disk.

---

## 7. What "any armv7 Linux" still cannot promise

- **Any app sandbox on Android.** `execve` from writable app storage is blocked
  for `targetSdk` ≥ 29 (that is precisely why Termux pins 28), and a normal
  Android app has no way to run an arbitrary ELF. `adb push` to
  `/data/local/tmp` + `chmod +x` works from a shell, Termux works because of its
  target SDK, and a *third-party* APK cannot host one without shipping it in
  `lib/<abi>/` and exec'ing from there.
- **Glue on Android is different, not just libs.** No netd resolver (§4), no
  `/tmp`, no `/etc/passwd`, `HOME` is not where users expect, `TMPDIR` may be
  unset, SELinux may deny paths an app could otherwise read.
- **No DNS without a resolver story**, as above. This is the single most likely
  reason a "portable" CLI fails on a phone while working on a router.
- **32-bit process limits**: 3 GB address space is not the issue on these
  devices; 512 MB RAM and one core are. Avoid buffering whole files, avoid ICU,
  avoid threads-per-connection designs.
- **Old kernels**: musl's fallbacks cover pre-5.1; kernels older than ~3.2 are
  plausible on 2011-era hardware and would need actual testing (QEMU with an old
  kernel, or the device).
- **No NSS, no PAM, no LDAP, no `/etc/ld.so.cache`** — sometimes fine, sometimes
  the whole point of the app (e.g. `sssd`-style tools are simply out of scope).

---

## 8. What I would build, smallest first

1. **The checker is already written and passing/failing correctly**:
   `/workspace/armv7-portability-check.sh`. It reads ELF machine/class/EABI
   version/hard-float flag, `PT_INTERP`, `DT_NEEDED`, `.ARM.attributes`
   (`CPU_arch`, `FP_arch`, NEON), glibc symbol versions, hardcoded loader paths,
   and flags `note` for the §5 environment files it finds referenced. Verified:
   fails the `cortex_a7` build (VFPv4 + NEON), fails the pre-fix Rust binary
   (NEON), passes the fixed C, Rust and blob binaries. This is the CI gate that
   makes the phrase "runs on any armv7 Linux" mean something.
2. **A one-page baseline profile** (build flags per toolchain, the kernel
   floor, the "no NEON, no statx-only, no CUPS/ICU/NSS" rules, the time_t
   policy per language) — the armv7 equivalent of what quick-sharun encodes.
3. **An environment shim** of ~100 lines (C, or a Rust crate): set
   `TERMINFO`, `SSL_CERT_FILE`, `TZDIR`, `TMPDIR` defaults pointing into the
   embedded blob, re-exec `argv[0]` with a clean `PATH` if needed, and expose
   the appended payload as a small read API. Link it into the app; it is the
   only thing the CLI world needs that sharun provides for GUI apps.
4. **A curated static set** built on that profile: `mpv`+FFmpeg (the real
   prize on 512 MB), `rsync`, `git`, `curl`/`wget`, `jq`, `tmux`, `nano`,
   `htop`, `unzip`/`7z`, `sqlite3`, `openssh` (client), `python`-free. Publish
   with the linter output as the claim, and a `SHA256SUMS`-style manifest; a
   "static-binaries but armv7 and verified" project.
5. Only then consider a carrier/AppImage-style wrapper, and only if a GUI need
   appears — the CLI case has no use for it.

---

## 9. Reproduction (what was run here)

```sh
# qemu-user for armv7 on an x86_64 host
curl -LO https://github.com/multiarch/qemu-user-static/releases/download/v7.2.0-1/qemu-arm-static
chmod +x qemu-arm-static

# C baseline, 20 KB static
zig cc -target arm-linux-musleabihf -mcpu=cortex_a8-neon -Os -s -o probe probe.c
./qemu-arm-static ./probe                    # ptr=4 long=4 time_t=8 off_t=8
readelf -A probe                             # VFPv3, no NEON
./qemu-arm-static -strace ./t 2>&1 | head    # clock_gettime64 first, then fallbacks

# Rust static, 344 KB, no ARM cross-gcc needed
rustup target add armv7-unknown-linux-musleabihf
# .cargo/config.toml: linker=zigcc wrapper with -mcpu, rustflags link-self-contained=no
cargo build --release --target armv7-unknown-linux-musleabihf
./qemu-arm-static target/armv7-unknown-linux-musleabihf/release/rp   # time_t=4

# single ELF + appended payload
python3 -c 'import struct;e=open("blob","rb").read();p=open("payload.txt","rb").read();
open("blob.bin","wb").write(e+p+struct.pack("<4sQQ",b"AV7B",len(e),len(p)))'
./qemu-arm-static ./blob.bin
/workspace/armv7-portability-check.sh probe blob.bin rp
```

Not measured here, and the things worth measuring next on real hardware
(Pi 2 / Orange Pi / an armv7 phone): startup time, RSS, and whether the
environment shim actually removes the last host dependency on Termux and on the
`adb shell`.

---

## 10. Converting an existing binary instead of rebuilding it (tested)

The question was whether "AnyLinux for armv7" requires building from source, or
whether an existing dynamically-linked armv7 ELF can be made portable. Answer:
**the libc/loader layer can be fixed without source; two other layers cannot.**
Tested with a wrapper written for this: `armv7-anywrap.sh`.

```sh
armv7-anywrap.sh -r <sysroot> [-o <outdir>] <binary> [extra files/dirs...]
#  sysroot = any extracted armhf/armv7h tree (Debian .debs, Arch Linux ARM rootfs)
#  emits   <outdir>/lib, <outdir>/app, <outdir>/AppRun
```

It reads the ELF header and `.ARM.attributes` and warns about what it cannot
fix; it walks `DT_NEEDED` recursively, copies the loader plus the whole closure
out of the sysroot, and writes an `AppRun` that execs the bundled loader with
`--library-path` — the same trick sharun uses, in ~100 lines of POSIX sh.

### 10.1 `jq` 1.6 (Debian 12 armhf): converted and verified

Payload: `jq` from `jq_1.6-2.1+deb12u2_armhf.deb`, 32-bit ARM EABI5, PIE,
`NEEDED libjq.so.1, libc.so.6, ld-linux-armhf.so.3`, `fp=VFPv3-D16`, no NEON.
Closure resolved from a sysroot built out of Debian's `libc6`, `libjq1`,
`libonig5`, `zlib1g` armhf debs.

```
$ armv7-anywrap.sh -r sysroot -o jqbundle sysroot/jq
payload:  sysroot/jq
  cpu=v7 fp=VFPv3-D16 simd=none
loader:   ld-linux-armhf.so.3 (126500 bytes)
libs:     4 copied (2172 KiB)
bundle:   jqbundle (2196 KiB)
```

Three runs of the *same* bundle:

| environment | result |
|---|---|
| x86_64 host, **no ARM libc anywhere** | `{"sum":6,"n":3,"who":"neucom"}` |
| **Alpine 3.24 armv7 (musl) rootfs**, no `libc.so.6` in it at all | identical output |
| same, uname faked to `3.10.0` then `2.6.32` | identical output |

Negative control, same binary with only `libc.so.6` in `lib/`:
`error while loading shared libraries: libjq.so.1: cannot open shared object file`
— i.e. the bundle is doing the work, not the host.

Caveat on the faked uname: it tests glibc's version checks, not real syscall
availability (qemu still hands the guest a modern kernel).

### 10.2 `yt-dlp` armv7l (PyInstaller): closure resolved, run blocked by the harness

Payload: `yt-dlp_linux_armv7l` from the 2026.10.26 release, 10.6 MB PIE plus a
67 MB `_internal/` tree. `NEEDED libdl.so.2, libz.so.1, libpthread.so.0,
libc.so.6, ld-linux-armhf.so.3`; symbol floor only `GLIBC_2.4`–`GLIBC_2.7`;
`fp=VFPv3-D16`, **no NEON** — the published armv7 build is baseline-clean, so
the only reason it does not run on a musl or old-glibc armv7 box is the loader
and libc, which the bundle supplies.

```
$ armv7-anywrap.sh -r sysroot -o ytbundle bundle/app/yt-dlp bundle/app/_internal
libs:     4 copied (1352 KiB)
bundle:   ytbundle (79420 KiB)
$ ld-linux-armhf.so.3 --library-path ytbundle/lib --list ytbundle/app/yt-dlp
	libdl.so.2 => .../ytbundle/lib/libdl.so.2
	libz.so.1 => .../ytbundle/lib/libz.so.1
	libpthread.so.0 => .../ytbundle/lib/libpthread.so.0
	libc.so.6 => .../ytbundle/lib/libc.so.6
	/lib/ld-linux-armhf.so.3 => .../ytbundle/lib/ld-linux-armhf.so.3
```

The closure resolves entirely inside the bundle — 1.3 MB of glibc carrying a
78 MB Python payload. The run itself could not be completed here: the
PyInstaller bootloader re-execs `/proc/self/exe`, and **qemu-user cannot
perform a nested exec at all** in this sandbox (verified: even a static
armv7 binary exec'ing another static armv7 binary fails with
`Exec format error`, because the host has no `binfmt_misc` entry). Under
emulation `/proc/self/exe` also reports the *interpreter*, not the payload.
So the final step needs a real armv7 board or `qemu-system-arm` with an armv7
kernel; the parts before and after the re-exec are verified.

Side note that matters more than the test: a 78 MB payload is 67 MB of Python,
not of glibc. Bundling an existing PyInstaller artifact works, but the resulting
"portable CLI" is a whole interpreter, while `jq`'s entire bundle is 2.2 MB.

### 10.3 What bundling fixes, and what still needs a rebuild

Fixed without source (verified above):

- missing or too-old host glibc, musl hosts, Android/Termux userspace;
- `libz`/`libjq`/`libonig`-class dependencies and their ordering;
- the `/lib/ld-linux-armhf.so.3` path assumption (we simply never let the kernel
  see it — the bundled loader is invoked explicitly).

Not fixed without source:

- **instruction set**: if the payload carries `NEON` or `VFPv4`, it still SIGILLs
  on A8/A9/non-NEON cores; no bundle changes that;
- **kernel/ABI assumptions baked into the payload and into the bundled glibc**
  (`statx`, `clone3`, `futex_time64`, `time64` opt-in);
- **a payload statically linked against glibc** — there is no safe way to point a
  static glibc binary at a different libc; it must be rebuilt against musl;
- **bionic/NDK binaries** — an Android-native ELF needs the Android linker and
  `libc.so` from bionic; you can bin-patch the interpreter path but you cannot
  hand it glibc, so the app must be rebuilt (that is what Termux does);
- **programs that re-exec `/proc/self/exe`** stay host-semantics-dependent, which
  is fine on real hardware but breaks under emulation (see 10.2).

So the rule of thumb: *portability of the loader/libc layer is a packaging
problem (bundle it); portability of the instruction set and syscall layer is a
build problem (rebuild it).* A release-artifact-only approach gets you the
former and leaves the latter unknown unless you check the attributes — which is
exactly what `armv7-portability-check.sh` and `armv7-anywrap.sh`'s report print.

```sh
# converting an existing dynamic armv7 binary instead of rebuilding it (§10)
armv7-anywrap.sh -r sysroot -o jqbundle sysroot/jq
echo '{"a":[1,2,3]}' | \
  qemu-arm-static "$PWD/jqbundle/lib/ld-linux-armhf.so.3" \
    --library-path "$PWD/jqbundle/lib" "$PWD/jqbundle/app/jq" -c '{sum:(.a|add)}'
# sysroot built from Debian armhf debs: libc6, libjq1, libonig5, zlib1g

---

## 11. Replicating the Anylinux pipeline for armv7 (built, tested end to end)

Anylinux is three stages: **deploy the closure** (quick-sharun), **run through a
bundled loader** (sharun as AppRun), **pack** (uruntime/appimagetool). None of
those has an armv7 build upstream. So each stage was either found as an
alternative or built:

| stage | upstream armv7? | what was used |
|---|---|---|
| deploy closure | quick-sharun: no | `armv7-anywrap.sh` (§10) — DT_NEEDED walk over a sysroot |
| AppRun / loader | sharun 3.8.3: no | **sharun built for `armv7-unknown-linux-musleabihf`** (patch below) |
| pack | uruntime 0.8.1, appimagetool 0.5.6: no | **AppImageKit `runtime-armhf`** + host `mksquashfs` |
| squashfs tools | n/a (packing is arch-neutral) | squashfs-tools 4.6.1 built for the *build host* |
| build driver | quick-sharun: no | `armv7-quick-appimage.sh` (§11.3) |

### 11.1 The two patches that make the toolchain exist

`patches/userland-execve-rust-armv7.patch` (pkgforge-dev's userland-execve-rust
v0.3.2 — the crate sharun uses to jump into the loader without `execve`):

- adds the missing `#[cfg(target_arch = "arm")] fn run(sp, entry)`: `mov sp, …;
  bx …`, the same shape as the existing aarch64/riscv64/loongarch64/powerpc64
  versions;
- normalises `AT_*` constants to `u64` in `push_auxv` — on 32-bit ARM the
  constants are `u32`, so the upstream code does not even compile for `arm`.

`patches/sharun-armv7.patch` (Anylinux-sharun 3.8.3):

- `src/utils.rs`: an `arm` entry in the loader-name table
  (`ld-linux-armhf.so.3`, `ld-musl-armhf.so.1`);
- `src/main.rs`: on arm every payload is 32-bit, so the "32-bit guest on a
  64-bit host" special case (use `lib32`, pass the payload positionally to the
  loader, skip the userland exec) must not apply. One `guest32` flag does that.
- `.cargo/config.toml`: an `armv7-unknown-linux-musleabihf` target section that
  links with `zig cc` (no cross gcc), plus a `[patch]` stanza pointing the
  userland-execve dependency at the patched crate.

It builds **unmodified upstream settings** otherwise: the pinned
`nightly-2026-09-11` toolchain, `build-std`, `panic-immediate-abort`, LTO. That
produces a **222 KB static musl armv7 `sharun`** with `Tag_FP_arch: VFPv3` and no
NEON (the zig wrapper carries `-mcpu=cortex_a8-neon`, §2).

```sh
rustup target add armv7-unknown-linux-musleabihf --toolchain nightly-2026-09-11
rustup component add rust-src --toolchain nightly-2026-09-11
cargo build --release --target armv7-unknown-linux-musleabihf
```

### 11.2 Packing: the alternative runtime and what it costs

`uruntime` (Anylinux's runtime: static, squashfs + dwarfs, zstd) has no armv7
build, and building it means cross-building its embedded helper binaries too —
out of scope for this test. The prebuilt alternative is AppImageKit's
`runtime-armhf` (still published in `continuous`), which produces a standard
type-2 AppImage: runtime ELF + appended squashfs.

Two real costs, both measured:

- **The AppImageKit armhf runtime is dynamically linked**:
  `interpreter /lib/ld-linux-armhf.so.3`. So the AppImage *itself* needs an
  armhf glibc on the host — exactly what an AnyLinux AppImage is supposed to
  avoid. It ran here only with a glibc prefix (`qemu-arm-static -L hostroot`).
  The payload is portable; the runtime wrapper is not.
- **It only understands xz and zlib squashfs** (`Squashfs image uses (null)
  compression, this version supports only xz, zlib`), i.e. no zstd, no lz4, no
  dwarfs. Anylinux's default compressor cannot be used at all with this runtime.
  Sizes for the jq bundle: xz 1.3 MB, zstd 1.4 MB (unusable with this runtime),
  2.4 MB AppDir. xz also costs more CPU to decompress on a Cortex-A8 than zstd.

So the correct long-term answer is still a static armv7 `uruntime`; the
AppImageKit runtime is a working stopgap that shows the format is sound.

### 11.3 The driver script

`armv7-quick-appimage.sh` mirrors quick-sharun's shape: sysroot in, AppDir out,
AppImage out, compressor/level from the environment, no interactivity (CI-safe).

```sh
SQUASHFS_COMP=xz \
armv7-quick-appimage.sh -r sysroot -s sharun-armv7 -n jq -o out sysroot/jq
```

It writes an Anylinux-style AppDir — `AppRun` (sharun), `bin/<name>` (hardlink
to AppRun), `.bin/<name>` (the real payload), `lib/` (loader + closure),
`share/`, `<name>.desktop` — then packs `runtime-armhf` + squashfs. No icon is
generated (house rule: never invent one; jq has none upstream).

### 11.4 Verified, stage by stage

Payload: Debian 12 armhf `jq` 1.6 — an existing, dynamically linked, glibc-only
armv7 binary, unchanged.

| step | result |
|---|---|
| deploy closure | 4 libs + loader, 2.2 MB → AppDir 2.4 MB |
| `sharun` built for armv7 | 222 KB static musl, `VFPv3`, no NEON |
| AppImage produced | **1.3 MB** type-2 AppImage (xz) |
| runtime `--appimage-extract` | works, no FUSE |
| extracted tree | `AppRun`, `bin/jq`, `.bin/jq`, `lib/…`, `share/`, `jq.desktop` |
| `bin/jq` (sharun as AppRun) | `{"ok":true,"via":"final AppImage"}` |
| same, musl Alpine armv7 rootfs | `{"ok":true,"host":"alpine"}` |
| host with no ARM libc at all | works (payload libc comes from the bundle) |

The one link not exercised here is the *runtime exec'ing AppRun*: qemu-user
cannot perform a nested `execve` in this sandbox (§10.2), and the AppImageKit
runtime is a dynamic glibc binary. Everything on both sides of that single
`execve` is verified. On real hardware it is the same call AppImages make
everywhere.

Nits worth fixing before this is published: sharun writes `lib/lib.path` inside
the AppDir at startup, which is read-only when mounted from an AppImage (it
warns and continues); there is no `.upd_info`/zsync update info and no icon,
because AppImageKit's `appimagetool-armhf` was not usable here (it needs
`mksquashfs` at runtime, i.e. a nested exec again).

---

## 12. The real thing: a static FUSE-less runtime, and a testable artifact

§11 got the format right but the wrapper wrong: AppImageKit's `runtime-armhf` is
dynamically linked to glibc, so the AppImage needed a glibc host and could never
run on Termux. That is a non-starter for the actual goal, so the runtime was
replaced with one written for this: **`aruntime`** (`/workspace/aruntime.c`,
67 KB static, `VFPv3`, no NEON, no `PT_INTERP`, no `DT_NEEDED`).

What it does: finds the appended squashfs, reads it itself, extracts to a cache
directory, exports `APPDIR`/`APPIMAGE`/`SHARUN_DIR`/`OWD`, execs `AppRun`. No
FUSE, no mount, no user namespaces, no host libc. That is the only design that
can work on:
- musl distros and old glibc distros (no libc dependency at all),
- Termux and the Android `adb shell` (no `/dev/fuse`, no userns, no exec from
  app storage - but a shell can run a binary from `/data/local/tmp`),
- read-only and `noexec`-rooted systems (nothing to mount).

Deliberate scope: squashfs 4.0, **gzip only**, `-no-fragments`. Fragments and
the other compressors are the next commits, not a redesign: the block reader is
already generic.

### 12.1 Layout and how the pieces fit

```
yt-dlp-armv7.AppImage
├── aruntime                static armv7 runtime (appended to the front)
└── squashfs (gzip)
    ├── AppRun              = sharun, built for armv7 (patched, §11.1)
    ├── AppRun.sh           yt-dlp's environment (PYTHONHOME, CA, TMPDIR)
    ├── bin/yt-dlp          hardlink to AppRun
    ├── dash                static armv7 dash: runs AppRun.sh with no /bin/sh
    ├── .bin/python3        the interpreter, exec'd through the bundled loader
    ├── .bin/yt_dlp_script.py
    ├── lib/                loader + libpython + python's C deps
    └── share/              python3.14 stdlib + yt_dlp + bundled CA bundle
```

Two Anylinux idioms doing real work here: **`AppRun.sh` + a bundled `dash`**
means the AppImage has no `/bin/sh` dependency (Android's is
`/system/bin/sh`, and a musl image should not rely on it), and **`.bin/`** keeps
`/proc/self/exe` and `../lib` resolving the way the payload expects.

### 12.2 Payload provenance: which distros can we take armv7 binaries from?

Checked in this session; "ships CLI packages" means a real armv7/armhf repo with
current content, not just a kernel port.

| distro | arch name | libc | status | yt-dlp 2026.10.26 |
|---|---|---|---|---|
| **Alpine** edge (and postmarketOS) | `armv7` | musl | **best source** | `yt-dlp-core` 2.6 MB apk + python3 |
| **Debian** 13 trixie | `armhf` | glibc 2.41 | alive, large | `yt-dlp` (arch: all, python) |
| **Ubuntu** 24.04 ports | `armhf` | glibc | alive | in universe |
| **Void** current | `armv7l` | glibc **and** musl | alive (42k armv7l pkgs) | `yt-dlp-2026.10.26_1.armv7l.xbps` |
| **openSUSE** Tumbleweed ports | `armv7hl` | glibc | alive but stale | `yt-dlp-0.10.0` — 4 years behind |
| Arch Linux ARM | `armv7h` | glibc | mirrors refused connections here; historically alive | n/a this session |
| Fedora | `armhfp` | glibc | **archived** (last: F36) | n/a |

So no, Alpine is not the only one — Debian/Ubuntu armhf and Void armv7l are
both healthy — but **Alpine edge is the best source for this purpose** because
it is musl (so the payload needs no glibc at all, which halves the bundle and
removes the `/etc/resolv.conf`-of-glibc problem), rolling, and it splits
`yt-dlp` into `yt-dlp-core` (code) + `yt-dlp` (dependency stub) which makes the
closure easy to compute.

### 12.3 What was verified, and what could not be

Verified in this session:

| check | result |
|---|---|
| `aruntime` attributes | static, `VFPv3`, no NEON, no interpreter, no `DT_NEEDED` |
| `dash` attributes | static, `VFPv3`, no NEON |
| squashfs append + locate | runtime finds the image at any byte offset |
| extraction of a 43 MB tree | complete, files byte-identical (`cmp`) |
| `APPDIR` exported before `AppRun` | yes |
| AppRun → AppRun.sh → payload, full chain | **proven natively** (x86_64 build of `aruntime` + real AppRun.sh + a payload: `Native AppRun.sh reached, args: hello world` / `payload ran natively`) |
| yt-dlp from the extracted tree | `--version` → `2026.10.26`; `--help` works |
| yt-dlp network | reached YouTube over TLS using the **bundled** CA bundle |
| TLS + CA + DNS as a whole | `api.github.com` fetch inside the emulated armv7 python |
| distro package survey | table above |

Not verifiable here, and why: qemu-user in this sandbox cannot `execve` an ARM
binary from inside an emulated process (no `binfmt_misc` outside it), so the one
edge — *the runtime exec'ing `AppRun`* — cannot be walked under emulation. Every
stage on both sides of it is verified, and the same sequence is proven natively.
The remaining risk is small and is exactly what the device test below settles.

### 12.4 Testing it yourself on Android / Termux

Artifact: `/workspace/yt-dlp-armv7.AppImage` (16 MB).

**Termux (armv7 device, no root):**

```sh
pkg install curl          # or use the browser to download
curl -LO https://example.invalid/yt-dlp-armv7.AppImage   # or: adb push
chmod +x yt-dlp-armv7.AppImage
./yt-dlp-armv7.AppImage --version
./yt-dlp-armv7.AppImage -f 'best' 'https://...'
```

Notes that matter on Android specifically:
- **Termux's `$HOME`** is `/data/data/com.termux/files/home`, which is
  `noexec`… but the runtime only *reads* the image and writes the extracted tree
  into `$TMPDIR`/`$HOME/.cache`; it execs from there. If `$HOME` is `noexec`,
  set `TMPDIR` to a directory that is not:
  `TMPDIR=/data/local/tmp ./yt-dlp-armv7.AppImage --version`
- **No `/etc/resolv.conf`.** musl's resolver reads that literal path. In Termux,
  run through `termux-chroot` (it provides one), or set up a resolver. This is
  the one thing a self-contained bundle cannot fix — see §4.
- **`/tmp` does not exist**; `AppRun.sh` defaults `TMPDIR` to `$HOME/tmp` and
  creates it.
- **Termux rewrites `$PREFIX`** but the bundle uses only `$APPDIR` set by the
  runtime, so nothing breaks.

**adb shell on an armv7 device (no Termux):**

```sh
adb push yt-dlp-armv7.AppImage /data/local/tmp/
adb shell
cd /data/local/tmp && chmod +x yt-dlp-armv7.AppImage
TMPDIR=/data/local/tmp ./yt-dlp-armv7.AppImage --version
```

`/data/local/tmp` is the one place the Android shell is allowed to execute from.
Expect the DNS caveat above: either point it at a resolver you provide, or pass
`--no-check-certificates`-free alternatives like an explicit IP-based test.

**A real armv7 Linux box (the ideal test):**

```sh
# Alpine armv7, Debian armhf, postmarketOS, Void armv7l, old Pi 2, TV box
scp yt-dlp-armv7.AppImage box:
ssh box 'chmod +x yt-dlp-armv7.AppImage && ./yt-dlp-armv7.AppImage --version'
```

**Rooted Android / proot, if the above hits a wall:** `proot -0 ./yt-dlp-armv7.AppImage --version`.

### 12.5 Reproducing the build

```sh
# 1. a sysroot from Alpine edge armv7 (musl) - the script is in the repo
python3 alpine-armv7-fetch.py sysroot yt-dlp-core

# 2. the two armv7 tools (both static, both VFPv3, no NEON)
./aruntime-build.sh /path/to/zlib-1.3.1     # -> aruntime-armv7   (67 KB)
./dash-build.sh /path/to/dash-0.5.13.5      # -> dash-armv7       (158 KB)

# 3. sharun, built for armv7 (patches/, §11.1) -> sharun-armv7

# 4. assemble + pack (gzip, no fragments: what aruntime reads)
armv7-anylinux-build.sh -s sharun-armv7 -r sysroot -n yt-dlp \
    --runtime aruntime -o out sysroot/usr/bin/yt-dlp
```

`armv7-anylinux-build.sh` defaults to `--runtime aruntime` and picks the matching
compressor; `--runtime appimagekit` still exists for type-2 compatibility, with
the glibc caveat from §11.2.

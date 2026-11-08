# yt-dlp — armv7 AnyLinux AppImage

An armv7 build of [yt-dlp](https://github.com/yt-dlp/yt-dlp) packaged the
[Anylinux](https://github.com/pkgforge-dev/Anylinux-AppImages) way: one file, no
install, no dependencies on the host.

It runs on armv7 **Linux** — Alpine, Debian/Ubuntu armhf, Void, postmarketOS,
Arch Linux ARM, old Raspberry Pis and TV boxes — and on **Termux / the Android
adb shell**, because it carries its own shell, its own loader, its own libc, its
own Python and its own CA bundle. The only things it takes from the system are
the kernel and a writable directory.

```
./yt-dlp-armv7.AppImage --version
./yt-dlp-armv7.AppImage 'https://example.com/video'
```

## Why this repository exists

Upstream Anylinux tools have no armv7 build. Verified against their releases:

| stage | upstream armv7 | here |
|---|---|---|
| deploy the closure | no `quick-sharun` | `tools/armv7-anywrap.sh` + `tools/alpine-armv7-fetch.py` |
| `AppRun` / loader trampoline | no `sharun` | `patches/` + `tools/build-armv7-tools.sh` |
| pack | no `uruntime`, no `appimagetool` | `src/aruntime.c` + `mksquashfs` |

So the pipeline is the same three stages in the same order, with the missing
pieces built here rather than a different approach invented.

## What deviates, and why

- **The runtime is `aruntime`, not `uruntime`.** AppImageKit still publishes a
  `runtime-armhf`, but it is dynamically linked to glibc, so the AppImage itself
  would need a glibc host — which defeats the point on musl distros and makes it
  useless on Termux. `aruntime` is a 67 KB static runtime that reads the
  appended squashfs itself and extracts it: **no FUSE, no mount, no user
  namespaces, no host libc.** Android apps are not granted any of the first
  three, so this is the only shape that reaches all the targets.
- **squashfs is gzip-only, with `-no-fragments`.** That is what `aruntime` can
  read today. zstd would produce a smaller image and is the next piece of work;
  the block reader is already generic.
- **No `.upd_info`, no zsync.** `appimagetool` has no armv7 build and `aruntime`
  does not implement self-updates. Claiming update support would be a lie.
- **The payload comes from Alpine edge armv7 (musl)**, not from a glibc distro.
  A musl payload needs no glibc at all: no version floor, no glibc resolver
  behaviour, and roughly half the bytes.

## Building

Needs `zig`, `rustup` with the pinned nightly, `squashfs-tools`, `python3` and
`git`. `get-dependencies.sh` installs all of it on Arch Linux, which is the
only recommended build host.

```sh
./get-dependencies.sh     # once
./make-appimage.sh        # -> dist/yt-dlp-armv7.AppImage
./tools/smoke-test.sh dist/yt-dlp-armv7.AppImage
```

## Testing on Android

```sh
adb push yt-dlp-armv7.AppImage /data/local/tmp/
adb shell
cd /data/local/tmp && chmod +x yt-dlp-armv7.AppImage
TMPDIR=/data/local/tmp ./yt-dlp-armv7.AppImage --version
```

`/data/local/tmp` is the one path the Android shell may execute from. In Termux
the same file works from `$HOME`; use `termux-chroot` if DNS fails, because
**musl's resolver reads `/etc/resolv.conf`, which Android does not have**. That
is the one host dependency a self-contained bundle cannot remove — see
[`docs/anylinux-armv7-notes.md`](docs/anylinux-armv7-notes.md) §4.

## Layout

```
make-appimage.sh          build driver (the quick-sharun equivalent)
get-dependencies.sh       build host + toolchain
src/aruntime.c            static FUSE-less AppImage runtime
AppDir/AppRun.sh          per-application environment
AppDir/yt-dlp.desktop     desktop entry
patches/                  armv7 ports of userland-execve-rust and Anylinux-sharun
tools/build-armv7-tools.sh    builds aruntime, dash and sharun for armv7
tools/aruntime-build.sh       aruntime alone
tools/alpine-armv7-fetch.py   dependency-resolving Alpine armv7 fetcher
tools/armv7-anywrap.sh        DT_NEEDED closure walk
tools/armv7-portability-check.sh  refuses NEON/VFPv4/dynamic binaries
tools/smoke-test.sh           what CI runs
docs/anylinux-armv7-notes.md  the long-form engineering notes
```

`docs/` is worth reading before changing the runtime or the patches: it records
what was measured on real binaries, what could not be verified without armv7
hardware, and why each deviation above exists.

## Deliberate omissions

- **No icon** — yt-dlp ships none and this repository will not invent one.
- **No `.upd_info` / zsync** — there is no armv7 `appimagetool`, and `aruntime`
  does not implement self-updates. Publishing update metadata that cannot be
  honoured would break `appimageupdatetool` for every user.
- **No transport archives** — the AppImage is the artifact. Recompressing an
  already-compressed squashfs buys under one percent.

## How it is verified

CI runs `tools/smoke-test.sh`, which executes the runtime for real and checks
that the squashfs extracts completely, that `yt_dlp` imports and reports the
version the build intended through the *bundled* loader, and that `AppRun.sh`
parses under the *bundled* dash. With `YTDLP_NETWORK_TEST=1` it also does a live
TLS request using the bundled CA bundle.

The one step CI cannot walk is the runtime's `execve` into `AppRun`: qemu-user
cannot nested-exec an armv7 binary and there is no armv7 CI runner. That call is
proven natively and is what the device test above settles.

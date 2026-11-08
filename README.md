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

Needs `zig`, `rustup` with the pinned nightly, `squashfs-tools`, `python3`, `git`
and `p7zip`. `get-dependencies.sh` installs all of it on Arch Linux, which is the
only recommended build host.

```sh
./get-dependencies.sh     # once
./make-appimage.sh        # -> dist/yt-dlp-armv7.AppImage
./tools/smoke-test.sh dist/yt-dlp-armv7.AppImage
```

`make-appimage.sh` also writes a `.7z` next to the AppImage. That is not part of
Anylinux; it exists because the AppImage is a touch over some chat upload limits,
and 7z with an ARM BCJ filter is the best that can be done on an already-gzipped
squashfs (0.8% — the payload is compressed twice, so there is little left).

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

No icon is shipped: yt-dlp has none upstream and this repository does not invent
one.

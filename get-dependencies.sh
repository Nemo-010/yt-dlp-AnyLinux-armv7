#!/bin/sh
set -eu

echo "Installing package dependencies..."
echo "---------------------------------------------------------------"
pacman -Syu --noconfirm --needed \
	base-devel        \
	curl              \
	git               \
	p7zip             \
	python            \
	rustup            \
	squashfs-tools    \
	zlib

echo "Installing the pinned zig..."
echo "---------------------------------------------------------------"
# Zig is the cross compiler for every armv7 object in this repo. It is pinned so
# the floating Arch package cannot change the output CPU baseline under us.
ZIG_VERSION=0.17.0
if ! command -v zig >/dev/null 2>&1; then
	curl -sfL -o /tmp/zig.tar.xz \
		"https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
	rm -rf /opt/zig && mkdir -p /opt/zig
	tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig
	ln -sf /opt/zig/zig /usr/local/bin/zig
	rm -f /tmp/zig.tar.xz
fi

echo "Installing the rust toolchain sharun pins..."
echo "---------------------------------------------------------------"
# Anylinux-sharun's rust-toolchain.toml pins this nightly and builds std from
# source, so rust-src is required alongside the armv7 target.
rustup toolchain install nightly-2026-09-11 --profile minimal --component rust-src
rustup target add armv7-unknown-linux-musleabihf --toolchain nightly-2026-09-11

# make cargo/rustc visible to later steps: each GitHub Actions run step is a
# fresh shell and does not source a profile
for p in cargo rustc rustup rustdoc; do
	[ -x "$HOME/.cargo/bin/$p" ] && ln -sf "$HOME/.cargo/bin/$p" "/usr/local/bin/$p"
done

echo "Installing the armv7 emulator used for the smoke test..."
echo "---------------------------------------------------------------"
# qemu-user-static, because the extracted payload is a musl armv7 binary and CI
# has to prove it runs. The release binary is used rather than a distro package
# so the version does not drift.
if ! command -v qemu-arm-static >/dev/null 2>&1; then
	curl -sfL -o /usr/local/bin/qemu-arm-static \
		https://github.com/multiarch/qemu-user-static/releases/download/v7.2.0-1/qemu-arm-static
	chmod +x /usr/local/bin/qemu-arm-static
fi

zig version
cargo --version
mksquashfs -version | head -n 1
qemu-arm-static --version | head -n 1

#!/usr/bin/env bash
# ==============================================================================
# build-qemu.sh: Download, patch, and build stealth QEMU 11.0.3
# ==============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
PREFIX="${PREFIX:-/opt/AutoVirt/emulator}"
BUILD_DIR="${BUILD_DIR:-$HERE/build/qemu}"
SRC_DIR="${SRC_DIR:-$HERE/src/qemu-11.0.3}"
PATCH_FILE="$HERE/patches/qemu-11.0.3-stealth.patch"
QEMU_TAG="v11.0.3"
QEMU_URI="https://github.com/qemu/qemu.git"

echo "=== [1/4] Checking prerequisites ==="
command -v git >/dev/null || { echo "git is required"; exit 1; }
command -v ninja >/dev/null || { echo "ninja is required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

echo "=== [2/4] Acquiring QEMU $QEMU_TAG source ==="
if [ ! -d "$SRC_DIR/.git" ]; then
    mkdir -p "$(dirname "$SRC_DIR")"
    echo "Cloning QEMU $QEMU_TAG into $SRC_DIR..."
    git clone --depth=1 --branch "$QEMU_TAG" "$QEMU_URI" "$SRC_DIR"
fi

cd "$SRC_DIR"

if git diff --quiet HEAD && [ -f "$PATCH_FILE" ]; then
    echo "=== [3/4] Applying stealth patch ==="
    git apply "$PATCH_FILE" || {
        echo "Failed to apply $PATCH_FILE cleanly. It may already be applied."
    }
else
    echo "Source directory is already modified or patched. Proceeding..."
fi

echo "=== [4/4] Configuring & Building QEMU ==="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -f "build.ninja" ]; then
    "$SRC_DIR/configure" \
        --target-list=x86_64-softmmu \
        --prefix="$PREFIX" \
        --without-default-features \
        --enable-kvm \
        --enable-linux-io-uring \
        --enable-linux-aio \
        --enable-pixman \
        --enable-opengl \
        --enable-sdl \
        --enable-spice \
        --enable-spice-protocol \
        --enable-libusb \
        --enable-libudev \
        --enable-pipewire \
        --enable-tpm \
        --enable-numa \
        --enable-seccomp \
        --enable-zstd \
        --enable-tools \
        --enable-modules \
        --disable-docs \
        --disable-werror \
        --disable-linux-user \
        --disable-bsd-user \
        --disable-tcg \
        --extra-cflags="-g0 -O3" \
        --extra-ldflags="-s"
fi

ninja -j"$(nproc)"

echo ""
echo "QEMU $QEMU_TAG compiled successfully in $BUILD_DIR!"
echo "To install to $PREFIX, run: sudo ninja -C $BUILD_DIR install"

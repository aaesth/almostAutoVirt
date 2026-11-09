#!/usr/bin/env bash
# ==============================================================================
# build-kvm.sh: Build and install patched KVM modules for running host kernel
# ==============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
RUNNING_KERNEL="$(uname -r)"
KERNEL_BASE_VER="$(echo "$RUNNING_KERNEL" | cut -d'_' -f1 | cut -d'-' -f1)"
KERNEL_MAJOR_MINOR="$(echo "$KERNEL_BASE_VER" | cut -d'.' -f1,2)"
PATCH_FILE="$HERE/patches/linux-kvm-6.18-stealth.patch"
SRC_DIR="${SRC_DIR:-$HERE/src/linux-$KERNEL_BASE_VER}"

# Detect Intel vs AMD
if grep -q "GenuineIntel" /proc/cpuinfo; then
    KVM_ARCH_MODULE="kvm-intel"
    KVM_MODPROBE_NAME="kvm_intel"
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    KVM_ARCH_MODULE="kvm-amd"
    KVM_MODPROBE_NAME="kvm_amd"
else
    KVM_ARCH_MODULE="kvm-intel"
    KVM_MODPROBE_NAME="kvm_intel"
fi

restore_stock() {
    echo "Restoring stock KVM modules..."
    local updates_dir="/lib/modules/${RUNNING_KERNEL}/updates/arch/x86/kvm"
    if [ -d "$updates_dir" ]; then
        sudo rm -rf "$updates_dir"
        sudo depmod -a "${RUNNING_KERNEL}"
        echo "Stock KVM modules restored."
    else
        echo "No custom KVM override found in $updates_dir."
    fi
    exit 0
}

if [[ "${1:-}" == "--restore" ]]; then
    restore_stock
fi

echo "=== [1/5] Finding kernel headers for $RUNNING_KERNEL ==="
HEADERS_DIR=""
for dir in "/lib/modules/${RUNNING_KERNEL}/build" \
           "/usr/lib/modules/${RUNNING_KERNEL}/build" \
           "/usr/src/kernel-headers-${RUNNING_KERNEL}" \
           "/usr/src/linux-headers-${RUNNING_KERNEL}"; do
    if [ -d "$dir" ] && [ -f "$dir/Makefile" ]; then
        HEADERS_DIR="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
        break
    fi
done

if [ -z "$HEADERS_DIR" ]; then
    echo "ERROR: Kernel headers for '$RUNNING_KERNEL' not found!"
    echo "Please install kernel headers for your distro:"
    echo "  Void:   xbps-install -S linux-headers (or linux${KERNEL_MAJOR_MINOR}-headers)"
    echo "  Arch:   pacman -S linux-headers"
    echo "  Debian: apt install linux-headers-${RUNNING_KERNEL}"
    echo "  Fedora: dnf install kernel-devel-${RUNNING_KERNEL}"
    exit 1
fi
echo "Found headers: $HEADERS_DIR"

echo "=== [2/5] Acquiring Linux kernel source for $KERNEL_BASE_VER ==="
if [ ! -d "$SRC_DIR/arch/x86/kvm" ]; then
    mkdir -p "$(dirname "$SRC_DIR")"
    echo "Cloning Linux kernel v$KERNEL_BASE_VER into $SRC_DIR..."
    git clone --depth=1 --branch "v$KERNEL_BASE_VER" \
        "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git" "$SRC_DIR" || {
        echo "Git clone failed; attempting tarball download..."
        curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_BASE_VER%%.*}.x/linux-${KERNEL_BASE_VER}.tar.xz" | tar -xJ -C "$(dirname "$SRC_DIR")"
    }
fi

cd "$SRC_DIR"

if git diff --quiet HEAD 2>/dev/null && [ -f "$PATCH_FILE" ]; then
    echo "=== [3/5] Applying KVM stealth patch ==="
    git apply "$PATCH_FILE" || {
        echo "Warning: git apply failed, patch may already be applied."
    }
fi

echo "=== [4/5] Compiling KVM modules ==="
make -C "$SRC_DIR" M=arch/x86/kvm -j"$(nproc)" modules

BUILT_KVM="$SRC_DIR/arch/x86/kvm/kvm.ko"
BUILT_ARCH="$SRC_DIR/arch/x86/kvm/${KVM_ARCH_MODULE}.ko"

[ -f "$BUILT_KVM" ] || { echo "ERROR: kvm.ko build failed!"; exit 1; }
[ -f "$BUILT_ARCH" ] || { echo "ERROR: ${KVM_ARCH_MODULE}.ko build failed!"; exit 1; }

echo "=== [5/5] Installing patched KVM modules ==="
UPDATES_DIR="/lib/modules/${RUNNING_KERNEL}/updates/arch/x86/kvm"
sudo mkdir -p "$UPDATES_DIR"

SAMPLE_MOD=$(find "/lib/modules/${RUNNING_KERNEL}/kernel/arch/x86/kvm" -name "kvm.ko*" 2>/dev/null | head -n 1)

if [[ "$SAMPLE_MOD" == *.zst ]]; then
    zstd -f -19 "$BUILT_KVM" -o "$BUILT_KVM.zst"
    zstd -f -19 "$BUILT_ARCH" -o "$BUILT_ARCH.zst"
    sudo cp -f "$BUILT_KVM.zst" "$UPDATES_DIR/"
    sudo cp -f "$BUILT_ARCH.zst" "$UPDATES_DIR/"
elif [[ "$SAMPLE_MOD" == *.xz ]]; then
    xz -f -k "$BUILT_KVM"
    xz -f -k "$BUILT_ARCH"
    sudo cp -f "$BUILT_KVM.xz" "$UPDATES_DIR/"
    sudo cp -f "$BUILT_ARCH.xz" "$UPDATES_DIR/"
else
    sudo cp -f "$BUILT_KVM" "$UPDATES_DIR/"
    sudo cp -f "$BUILT_ARCH" "$UPDATES_DIR/"
fi

sudo depmod -a "${RUNNING_KERNEL}"

echo "Reloading KVM modules..."
sudo modprobe -r "$KVM_MODPROBE_NAME" 2>/dev/null || true
sudo modprobe -r kvm 2>/dev/null || true
sudo modprobe kvm
sudo modprobe "$KVM_MODPROBE_NAME"

ACTIVE_PATH=$(modinfo -F filename "$KVM_MODPROBE_NAME")
echo "Active $KVM_MODPROBE_NAME module: $ACTIVE_PATH"
echo "KVM modules installed and reloaded successfully!"

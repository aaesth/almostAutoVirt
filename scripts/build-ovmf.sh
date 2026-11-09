#!/usr/bin/env bash
# ==============================================================================
# build-ovmf.sh: Build stealth OVMF UEFI firmware from EDK2
# ==============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC_DIR="${SRC_DIR:-$HERE/src/edk2-stable202605}"
PATCH_FILE="$HERE/patches/edk2-stable202605-stealth.patch"
OUT_DIR="${OUT_DIR:-$HERE/firmware}"
EDK2_TAG="edk2-stable202605"
EDK2_URI="https://github.com/tianocore/edk2.git"

echo "=== [1/4] Acquiring EDK2 source ==="
if [ ! -d "$SRC_DIR/.git" ]; then
    mkdir -p "$(dirname "$SRC_DIR")"
    echo "Cloning EDK2 $EDK2_TAG into $SRC_DIR..."
    git clone --depth=1 --branch "$EDK2_TAG" "$EDK2_URI" "$SRC_DIR"
    cd "$SRC_DIR"
    git submodule update --init --depth=1
else
    cd "$SRC_DIR"
fi

echo "=== [2/4] Applying stealth patch ==="
if git diff --quiet HEAD 2>/dev/null && [ -f "$PATCH_FILE" ]; then
    git apply "$PATCH_FILE" || {
        echo "Warning: git apply failed, patch may already be applied."
    }
fi

echo "=== [3/4] Building BaseTools ==="
make -C BaseTools -j"$(nproc)"

echo "=== [4/4] Building OVMF (X64, SMM, Secure Boot) ==="
export WORKSPACE="$SRC_DIR"
export EDK_TOOLS_PATH="$SRC_DIR/BaseTools"
source "$SRC_DIR/edksetup.sh"

build -a X64 -p OvmfPkg/OvmfPkgX64.dsc -b RELEASE -t GCC5 \
    -D SECURE_BOOT_ENABLE=TRUE \
    -D SMM_REQUIRE=TRUE \
    -D TPM2_ENABLE=TRUE

BIN_DIR="$SRC_DIR/Build/OvmfX64/RELEASE_GCC5/FV"
mkdir -p "$OUT_DIR"
cp -f "$BIN_DIR/OVMF_CODE.fd" "$OUT_DIR/OVMF_CODE.fd"
cp -f "$BIN_DIR/OVMF_VARS.fd" "$OUT_DIR/OVMF_VARS.fd"

echo "Stealth OVMF built successfully into $OUT_DIR/!"

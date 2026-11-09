#!/usr/bin/env bash
# ==============================================================================
# install.sh: Master Installer for win10-stealth VM
#
# Installs patched QEMU 11.0.3, fixed SMBIOS table, patched KVM kernel modules,
# stealth OVMF firmware, and defines/updates the win10-stealth VM in libvirt.
#
# Usage: sudo ./install.sh [disk_path]
# ==============================================================================
set -euo pipefail

DISK="${1:-/var/lib/libvirt/images/win11.qcow2}"
OLD_NVRAM="/var/lib/libvirt/qemu/nvram/AutoVirt_VARS.fd"
NEW_NVRAM="/var/lib/libvirt/qemu/nvram/win10-stealth_VARS.fd"
HERE=$(cd "$(dirname "$0")" && pwd)
KVER=$(uname -r)
VIRSH="virsh -c qemu:///system"

echo "=== AutoVirt 2.0 Stealth VM Installer ==="
echo "Target disk: $DISK"

[ -f "$DISK" ] || { echo "ERROR: Disk not found: $DISK" >&2; exit 1; }

# Ensure disk is not currently locked by an active VM
for vm in $($VIRSH list --name 2>/dev/null || true); do
    if [ -n "$vm" ] && $VIRSH domblklist "$vm" 2>/dev/null | grep -qF "$DISK"; then
        echo "VM '$vm' is running with $DISK; shut it down first." >&2
        exit 1
    fi
done

# Ensure split-lock mitigation does not trap or throttle guest vCPUs
sysctl -w kernel.split_lock_mitigate=0 >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 1. Stealth OVMF Firmware
# ------------------------------------------------------------------------------
echo "[1/5] Setting up stealth OVMF firmware (/opt/AutoVirt/firmware) ..."
mkdir -p /opt/AutoVirt/firmware
if [ -f "$HERE/firmware/OVMF_CODE.fd" ] && [ -f "$HERE/firmware/OVMF_VARS.fd" ]; then
    cp -f "$HERE/firmware/OVMF_CODE.fd" /opt/AutoVirt/firmware/
    cp -f "$HERE/firmware/OVMF_VARS.fd" /opt/AutoVirt/firmware/
    echo "      Copied stealth OVMF binaries to /opt/AutoVirt/firmware/"
elif [ ! -f /opt/AutoVirt/firmware/OVMF_CODE.fd ]; then
    echo "      Building stealth OVMF from source..."
    "$HERE/scripts/build-ovmf.sh"
    cp -f "$HERE/firmware/OVMF_CODE.fd" /opt/AutoVirt/firmware/
    cp -f "$HERE/firmware/OVMF_VARS.fd" /opt/AutoVirt/firmware/
fi

# ------------------------------------------------------------------------------
# 2. Stealth QEMU 11.0.3 Emulator
# ------------------------------------------------------------------------------
echo "[2/5] Ensuring patched QEMU 11.0.3 is installed (/opt/AutoVirt/emulator) ..."
mkdir -p /opt/AutoVirt/emulator
if [ -f /home/lain/git/AutoVirt/src/v11.0.3/build/build.ninja ]; then
    ninja -C /home/lain/git/AutoVirt/src/v11.0.3/build install >/dev/null
    echo "      Installed QEMU from local build cache."
elif [ ! -f /opt/AutoVirt/emulator/bin/qemu-system-x86_64 ]; then
    echo "      Building patched QEMU 11.0.3 from source..."
    "$HERE/scripts/build-qemu.sh"
    ninja -C "$HERE/build/qemu" install >/dev/null
else
    echo "      Existing QEMU binary found at /opt/AutoVirt/emulator/bin/qemu-system-x86_64."
fi

# ------------------------------------------------------------------------------
# 3. Generating Fixed SMBIOS Table
# ------------------------------------------------------------------------------
echo "[3/5] Generating fixed SMBIOS table (/opt/AutoVirt/firmware/smbios.bin) ..."
SMBIOS_SCRIPT="$HERE/scripts/SMBIOS.py"
if [ ! -f "$SMBIOS_SCRIPT" ]; then
    SMBIOS_SCRIPT="/home/lain/git/AutoVirt/resources/scripts/Linux/SMBIOS.py"
fi

python3 "$SMBIOS_SCRIPT" \
    --cores 6 --threads 12 \
    --cpu-version "12th Gen Intel(R) Core(TM) i5-12400F" \
    --ram-gb 16 \
    -o /opt/AutoVirt/firmware/smbios.bin
echo "      SMBIOS table generated successfully."

# ------------------------------------------------------------------------------
# 4. Building, Installing, and Reloading Patched KVM Modules
# ------------------------------------------------------------------------------
echo "[4/5] Building & installing patched KVM modules for kernel $KVER ..."
if [ -d "/home/lain/git/AutoVirt/src/linux-6.18.54" ]; then
    make -C "/home/lain/git/AutoVirt/src/linux-6.18.54" M=arch/x86/kvm -j"$(nproc)" modules
    KVM_DIR="/home/lain/git/AutoVirt/src/linux-6.18.54/arch/x86/kvm"
    if [ "$KVM_DIR/kvm.ko" -nt "$KVM_DIR/kvm.ko.zst" ]; then
        zstd -f -19 "$KVM_DIR/kvm.ko" -o "$KVM_DIR/kvm.ko.zst"
    fi
    if [ "$KVM_DIR/kvm-intel.ko" -nt "$KVM_DIR/kvm-intel.ko.zst" ]; then
        zstd -f -19 "$KVM_DIR/kvm-intel.ko" -o "$KVM_DIR/kvm-intel.ko.zst"
    fi
    UPDATES_DIR="/lib/modules/$KVER/updates/arch/x86/kvm"
    mkdir -p "$UPDATES_DIR"
    cp -f "$KVM_DIR/kvm.ko.zst" "$UPDATES_DIR/"
    cp -f "$KVM_DIR/kvm-intel.ko.zst" "$UPDATES_DIR/"
    depmod -a "$KVER"
    modprobe -r kvm_intel 2>/dev/null || true
    modprobe -r kvm 2>/dev/null || true
    modprobe kvm
    modprobe kvm_intel
    echo "      Active kvm_intel: $(modinfo -F filename kvm_intel)"
else
    "$HERE/scripts/build-kvm.sh"
fi

# ------------------------------------------------------------------------------
# 5. Defining win10-stealth in Libvirt
# ------------------------------------------------------------------------------
echo "[5/5] Defining win10-stealth in libvirt ..."
if [ -f "$OLD_NVRAM" ] && [ ! -e "$NEW_NVRAM" ]; then
    cp -p "$OLD_NVRAM" "$NEW_NVRAM"
    echo "      Copied $OLD_NVRAM -> $NEW_NVRAM"
fi

sed -e "s|@DISK@|$DISK|" "$HERE/win10-stealth.xml.in" > "$HERE/win10-stealth.xml"
$VIRSH define "$HERE/win10-stealth.xml"

if $VIRSH dominfo AutoVirt >/dev/null 2>&1; then
    $VIRSH dumpxml AutoVirt > "$HERE/AutoVirt.backup.xml"
    $VIRSH undefine AutoVirt --keep-nvram --keep-tpm
    echo "      Undefined AutoVirt (XML backed up to $HERE/AutoVirt.backup.xml)"
fi

echo ""
echo "Done! All components (QEMU, OVMF, SMBIOS, KVM modules, libvirt XML) are installed."
echo "You can now start the VM with: virsh -c qemu:///system start win10-stealth"

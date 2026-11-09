# almostAutoVirt
> [!NOTE]  
> This AI slop project is public incase anyone wants to copy anything from here

> [!IMPORTANT]
> This is tuned to my system and you will probably have to tune it to your system before anything works, 
> Nothing here is guaranteed to be the same on your system

<img src=https://raw.githubusercontent.com/aaesth/almostAutoVirt/refs/heads/main/img-2026-11-09-21-57-45.png>

hardened KVM vm setup for windows 10 with dedicated PCIe GPU passthrough that achieves a 100% bare metal rate on vmaware YMMV YMMV YMMV YMMV and it should work with memory integrity YMMV YMMV YMMV, TPM 2.0 works but it causes a detection which I cba to fix.

## Highlights
  * ACPI System Timers (`PNP0100` PIT, `PNP0B00` RTC, `PNP0103` HPET).
  * SMBIOS Type 0 integrity & table duplication fixes (strips `_SM3_` anchor header, preserves AMI BIOS structures).
  * CPUID & SMBIOS topology unification (Intel Core i5-12400F 6C/12T, eliminates hybrid core leakage from Raptor Lake / Alder Lake hosts).
  * PCI device & subsystem vendor spoofing (Gigabyte `1458:5001`, Phison NVMe `1987:5013`, eliminates Red Hat `1AF4`/`1B36` IDs).
  * Ring 3 `VMCALL`/`VMMCALL` handling (unconditional `#UD` injection without guest memory patching).
  * Single-step `#DB` and interrupt shadow order preservation (`MOV SS` blocking, `DR6.BS` handling).
  * Hardware-native `RDTSC`/`RDTSCP` timing with dynamic `CPUID` VM-exit cycle latency compensation (~150 cycles).
  * cool evdev input switching

## Structure
```
autovirt2/
├── install.sh                  # One-click master installer & updater
├── win10-stealth.xml.in        # Libvirt domain XML template (fully documented)
├── win10-stealth.xml           # Generated domain XML reference
├── firmware/
│   ├── OVMF_CODE.fd            # Precompiled stealth OVMF UEFI firmware
│   └── OVMF_VARS.fd            # Precompiled stealth OVMF UEFI NVRAM template
├── patches/
│   ├── qemu-11.0.3-stealth.patch      # Complete QEMU 11.0.3 stealth patch
│   ├── linux-kvm-6.18-stealth.patch   # Complete Linux KVM (6.18+) stealth patch
│   └── edk2-stable202605-stealth.patch # EDK2 OVMF UEFI patch
├── scripts/
│   ├── SMBIOS.py               # Host SMBIOS extractor & generator
│   ├── build-qemu.sh           # Standalone QEMU download, patch & build script
│   ├── build-kvm.sh            # Standalone out-of-tree KVM module compiler
│   └── build-ovmf.sh           # Standalone EDK2 OVMF compiler
└── docs/
    ├── VMAWARE_DETECTIONS.md   # Detailed breakdown of all VMAware checks & fixes
    ├── CORE_ISOLATION_AND_HVCI.md # Root-cause analysis of HVCI/VBS crash & MSR fix
    └── GPU_PASSTHROUGH_SETUP.md # Host GPU isolation, IOMMU & kernel params guide
```

## Quickstart
> [!CAUTION]
> I'm not responsible for anything that happens to your computer, These scripts are written by Gemini 4.0 Argon
### 1. Prerequisites
* **Host OS**: Linux (tested on Void Linux with kernel 6.18.54_1)
* **Hardware**: Intel CPU with VT-x & VT-d (tested on i7-14700KF, B660 motherboard).
* **Dedicated GPU**: Secondary GPU bound to `vfio-pci` (see [GPU Passthrough Guide](docs/GPU_PASSTHROUGH_SETUP.md)).
* **Disk Image**: An existing Windows 10/11 QCOW2 or raw disk image (e.g. `/var/lib/libvirt/images/win11.qcow2`).

### 2. Installation
Run the installer as root, specifying your disk image path:

```sh
git clone https://github.com/your-username/autovirt2.git
cd autovirt2
sudo ./install.sh /var/lib/libvirt/images/win11.qcow2
```

The installer will:
1. Verify disk availability and host split-lock parameters (`kernel.split_lock_mitigate=0`).
2. Deploy stealth OVMF firmware to `/opt/AutoVirt/firmware`.
3. Verify or build the patched QEMU 11.0.3 binary in `/opt/AutoVirt/emulator`.
4. Generate `/opt/AutoVirt/firmware/smbios.bin` from your physical host motherboard.
5. Compile and install patched `kvm` and `kvm-intel` modules into `/lib/modules/$(uname -r)/updates/`.
6. Define and configure the `win10-stealth` VM in libvirt.

### 3. Launching the VM
```sh
virsh -c qemu:///system start win10-stealth
```

* Tap **Scroll Lock** to toggle keyboard and mouse grab between host and guest.

## Guest Configuration

1. **Clean Legacy Device Drivers**:
   * Open **Device Manager** -> **View** -> **Show hidden devices**.
   * Uninstall any ghost display adapters (QXL, Microsoft Basic Display), Red Hat VirtIO controllers, or QEMU devices.
2. **Run VMAware**:
   * Download and run [VMAware](https://github.com/kernelmode/VMAware) to check the detections.

## In-Depth Documentation

* [VMAware Detection Breakdown](docs/VMAWARE_DETECTIONS.md)
* [Core Isolation, HVCI & Vanguard MSR Fix](docs/CORE_ISOLATION_AND_HVCI.md)
* [Host GPU Passthrough & VFIO Setup](docs/GPU_PASSTHROUGH_SETUP.md)

<img src=https://raw.githubusercontent.com/aaesth/almostAutoVirt/refs/heads/main/img-2026-11-09-22-02-29.png>

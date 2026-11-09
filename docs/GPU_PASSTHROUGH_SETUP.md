# GPU Passthrough & Host Isolation Guide

This guide covers host configuration for isolating a secondary GPU for dedicated VM passthrough (specifically tested with an NVIDIA GeForce RTX 4070 on Void GNU/Linux, but applicable to any modern distribution).

---

## 1. Host Kernel Parameters

Edit your bootloader configuration (e.g., GRUB in `/etc/default/grub` or systemd-boot entry):

```sh
intel_iommu=on iommu=pt kvm.ignore_msrs=1 kernel.split_lock_mitigate=0 vfio-pci.ids=10de:2786,10de:22bc
```

* `intel_iommu=on`: Enables Intel VT-d translation.
* `iommu=pt`: Uses pass-through translation for host devices for lower overhead.
* `kvm.ignore_msrs=1`: Ignores unhandled MSR reads/writes to prevent guest crash on unimplemented vendor MSRs.
* `kernel.split_lock_mitigate=0`: Disables CPU split-lock throttling.
* `vfio-pci.ids=10de:2786,10de:22bc`: Binds the GPU video and HDMI audio functions to `vfio-pci` before display managers or the host `nvidia`/`nouveau` driver can claim them.

Update your bootloader:
```sh
# On Void / Debian / Ubuntu:
sudo update-grub
```

---

## 2. Early VFIO Binding (Dracut / Initramfs)

Ensure `vfio-pci` loads ahead of standard graphics drivers.

### `/etc/dracut.conf.d/vfio.conf` (Dracut):
```ini
add_drivers+=" vfio vfio_iommu_type1 vfio_pci "
```

### `/etc/modprobe.d/vfio.conf`:
```ini
options vfio-pci ids=10de:2786,10de:22bc
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
```

Rebuild your initramfs:
```sh
# On Void Linux:
sudo dracut --regenerate-all --force
```

---

## 3. Verifying IOMMU Groups

Check that the GPU resides in its own isolated IOMMU group:
```sh
for d in /sys/kernel/iommu_groups/*/devices/*; do
    n=${d#*/iommu_groups/*}; n=${n%%/*}
    printf 'IOMMU Group %s ' "$n"
    lspci -nns "${d##*/}"
done | grep -E "VGA|Audio"
```

The GPU (`01:00.0`) and its HDMI audio (`01:00.1`) should share an isolated group without host chipset bridges or storage controllers.

---

## 4. Seamless Evdev Input Sharing

Instead of USB pass-through (which can be queried or delayed by VM checks), this setup feeds raw Linux evdev event streams directly into the virtual PS/2 controller:

```xml
<input type='mouse' bus='ps2'/>
<input type='keyboard' bus='ps2'/>
<input type='evdev'>
  <source dev='/dev/input/by-id/usb-_X68HE-event-kbd' grab='all' grabToggle='scrolllock' repeat='on'/>
</input>
<input type='evdev'>
  <source dev='/dev/input/by-id/usb-Logitech_G502_HERO_Gaming_Mouse_206E39B74145-event-mouse' grabToggle='scrolllock'/>
</input>
```

* **Toggle Key**: Tap **Scroll Lock** to switch input control between host and guest with zero latency.
* **Stealth**: Windows sees generic PS/2 keyboard and mouse devices, eliminating QEMU USB tablet/mouse signatures.

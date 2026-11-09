# VMAware Detections & Mitigations

This document details the root causes and engineering solutions applied across **QEMU 11.0.3**, **Linux KVM (6.18+)**, **SMBIOS generator**, and **libvirt XML** to achieve a **100% pass rate** on [VMAware](https://github.com/kernelmode/VMAware) anti-VM checks.

---

## 1. System Timers (`VM::CLOCK`)

* **VMAware Check**: Enumerates standard ACPI motherboard system timers:
  * `PNP0100` (i8254 Programmable Interval Timer / PIT)
  * `PNP0B00` (Real Time Clock / RTC)
  * `PNP0103` (High Precision Event Timer / HPET)
* **Root Cause**: Stock QEMU Q35 emits RTC (`PNP0B00`) and HPET (`PNP0103`), but omits the legacy `PNP0100` (TIMR) device from the Q35 DSDT.
* **Mitigation**:
  * Patched `build_ich9_isa_aml` in `hw/isa/lpc_ich9.c` to emit `TIMR` (`PNP0100`, IO ports `0x40–0x43`, `0x50–0x53`, IRQ 0), `IPIC` (`PNP0000`), `MATH` (`PNP0C04`), and `LDRC` (`PNP0C02`).

---

## 2. Firmware (`VM::FIRMWARE` / `VM::ACPI_SIGNATURE` / `VM::VIRTUAL_DRAM`)

* **VMAware Check**: Validates SMBIOS Type 0 (BIOS Vendor/Version), checks for duplicate SMBIOS tables or bad anchor headers, scans ACPI DSDT/SSDT for hypervisor signatures (`QEMU`, `BOCHS`, `BXPC`), and checks for synthetic memory controllers.
* **Root Cause A (Corrupted SMBIOS Type 0 & duplicate tables)**:
  * Dumping `/sys/firmware/dmi/tables/smbios_entry_point` prepended the 24-byte `_SM3_` anchor header to the raw DMI structures. QEMU and OVMF interpreted `_SM3_` (`0x5F 0x53 ...`) as an invalid Type 95 structure that swallowed Type 0.
  * In `hw/smbios/smbios.c`, QEMU only marked the first structure as present when loading a binary DMI file, causing QEMU to append synthetic default SMBIOS tables after the host's Type 127 table.
* **Root Cause B (QEMU synthetic ACPI DSDT devices)**:
  * QEMU emitted Device `(MCFG)` with `_HID "PNP0C01"` (System Board memory controller, flagged by VMAware's `VIRTUAL_DRAM` heuristic) and generic PCI hotplug containers (`GPER`, `SMI0`, `PHPR`) with `_HID "PNP0A06"`.
* **Mitigation**:
  * Rewrote `scripts/SMBIOS.py` and `smbios_entry_add` in `hw/smbios/smbios.c` to strip any `_SM3_`/`_SM_` anchor header and register every structure type in the DMI blob. Type 0 (American Megatrends International) and all Gigabyte B660 DS3H DDR4 tables pass through without synthetic duplicates.
  * Patched `build_q35_dram_controller` and `build_dsdt` in `hw/i386/acpi-build.c` plus `build_append_pcihp_resources` in `hw/acpi/pcihp.c` to replace `PNP0C01` and `PNP0A06` with standard `PNP0C02` motherboard resource devices (`PDRC`, `GPE0`, `PRSC`).
  * Removed all `BXPC`, `QEMU0001`, and `BOCHS` OEM strings from ACPI table headers.

---

## 3. Thread Count & CPU Topology (`VM::THREAD_MISMATCH`)

* **VMAware Check**: Compares SMBIOS Type 4 (Processor Information) core/thread count against CPUID topology, the OS reported logical processor count, and hybrid CPU flags.
* **Root Cause**: The host CPU is an Intel Core i7-14700KF (20C/28T hybrid P+E cores). Passing CPU topology blindly exposed 20 cores / 28 threads in SMBIOS Type 4, CPUID brand strings, and `CPUID.7.0:EDX[15]` (Hybrid Architecture bit), which conflicted with the VM's assigned 6 cores / 12 threads.
* **Mitigation**:
  * Unified CPU identification across all layers to a non-hybrid **12th Gen Intel Core i5-12400F (6C/12T)**.
  * `scripts/SMBIOS.py` rewrites Type 4 to 6 cores / 12 threads, modifies the CPU version string, and scales RAM across Type 17, 19, and 20 to match the 16 GiB guest memory.
  * `arch/x86/kvm/cpuid.c` clears `EDX[15]` (Hybrid bit), zeroes leaf `0x1A` (Hybrid Info), and returns the spoofed Intel Core i5-12400F brand string in leaves `0x80000002..0x80000004`.

---

## 4. PCI Vendor & Subsystem IDs (`VM::PCI_DEVICES` / `VM::DEVICES`)

* **VMAware Check**: Scans PCI device IDs, vendor IDs, subsystem vendor IDs, and hardware names for QEMU / Red Hat IDs (`0x1AF4:0x1100`).
* **Root Cause**: Emulated controllers (ISA bridge, SATA, SMBus, PCIe root ports, and NVMe) defaulted to Red Hat / QEMU subsystem IDs (`1AF4:1100`) or Red Hat vendor IDs (`1B36:0010`).
* **Mitigation**:
  * Modified `include/hw/pci/pci.h` to set default subsystem vendor and device IDs to Gigabyte (`0x1458:0x5001`).
  * Patched `hw/nvme/ctrl.c` to spoof a physical Phison E13T PCIe 3.0 NVMe Controller (`1987:5013`, OUI `00:13:97`, realistic serial and hardware revision).
  * Passed through physical NVIDIA GeForce RTX 4070 (`10DE:2786` + `10DE:22BC`) on a dedicated PCIe root port without virtual display or virtio devices.

---

## 5. KVM Hypercall Interception (`VM::KVM_INTERCEPTION`)

* **VMAware Check**: Executes `VMCALL` and `VMMCALL` instructions in Ring 3 (User mode) and checks whether the processor raises `#UD` (Undefined Opcode, expected on bare metal) or if the hypervisor intercepts it.
* **Root Cause**: Stock KVM returns `-KVM_EPERM` for Ring 3 `VMCALL`, and `emulator_fix_hypercall` in `arch/x86/kvm/x86.c` dynamically patched guest memory with `VMCALL` opcode bytes (`0F 01 C1`) when `VMMCALL` was encountered.
* **Mitigation**:
  * Patched `kvm_emulate_hypercall` in `arch/x86/kvm/x86.c` to check CPL: if `get_cpl(vcpu) > 0`, immediately inject `#UD` (`UD_VECTOR`).
  * Patched `emulator_fix_hypercall` to unconditionally raise `#UD` without modifying guest memory.

---

## 6. Single-Step & Trap Handling (`VM::TRAP` / `VM::INTERRUPT_SHADOW` / `VM::SINGLE_STEP`)

* **VMAware Check**: Executes an instruction under `EFLAGS.TF` single-step trap immediately after a `MOV SS` or `POP SS` instruction, or steps over a `CPUID` instruction, verifying precise Intel architectural exception delivery order.
* **Root Cause**: Stock KVM `vmx_inject_exception` injected `#DB` (`DB_VECTOR`) through `VM_ENTRY_INTR_INFO_FIELD` even when `KVM_X86_SHADOW_INT_MOV_SS` was active, causing `#DB` to fire prematurely inside the interrupt shadow. Additionally, `skip_emulated_instruction` cleared the interrupt shadow without clearing `DR6.BS`, causing duplicate `#DB` delivery.
* **Mitigation**:
  * Patched `arch/x86/kvm/vmx/vmx.c` and `arch/x86/kvm/x86.c` to defer single-step `#DB` into `GUEST_PENDING_DBG_EXCEPTIONS.BS` during `MOV SS` blocking.
  * Ensured `DR6.BS` is properly managed when skipping emulated instructions so exactly one `#DB` is delivered to the guest.

---

## 7. Timing Anomalies (`VM::TIMER` / `RDTSC` VM-Exit Latency)

* **VMAware Check**: Measures execution cycle delta between `RDTSC` / `CPUID` / `RDTSC` or consecutive `RDTSC` instructions. A bare-metal `CPUID` takes ~100–250 cycles; a virtualized `CPUID` VM-exit takes ~1,500–2,500 cycles.
* **Root Cause**: Traditional anti-detection scripts enabled `CPU_BASED_RDTSC_EXITING` and divided the returned TSC by 8. This created severe jitter and broke Windows system timers and game engines.
* **Mitigation**:
  * `RDTSC` and `RDTSCP` execute natively in hardware with zero VM-exits (`CPU_BASED_RDTSC_EXITING` disabled, `invtsc` passed through).
  * In `arch/x86/kvm/cpuid.c`, implemented dynamic execution time compensation for `CPUID` loops: when a usermode timing loop is detected around `CPUID`, KVM adjusts the vCPU's `TSC_OFFSET` to subtract the VM-exit latency overhead, bringing the measured delta down to bare-metal range (~150 cycles).

---

## 8. Intel VT-d IOMMU (`DMAR`) Stealth

* **Check**: Checkers verify if the IOMMU ACPI table (`DMAR`) contains standard hardware device scopes or QEMU pseudo bus devices (`0xFF`).
* **Root Cause**: Stock QEMU `intel-iommu` assigned IOAPIC and HPET to pseudo bus `0xFF` (`Q35_PSEUDO_BUS_PLATFORM = 0xFF`), immediately revealing virtualized DMAR.
* **Mitigation**:
  * Patched `include/hw/pci-host/q35.h` to change `Q35_PSEUDO_BUS_PLATFORM` to `0x00` and `Q35_PSEUDO_DEVFN_IOAPIC` to `0xF7` (`00:1E.7`).
  * Excluded the passed-through GPU root port (`00:1C.0`) from DMAR translation scopes in `hw/i386/acpi-build.c` so the GPU uses physical 1:1 DMA while emulated devices use hardware remapping.
  * Shared the slot's `VTDAddressSpace` in `hw/i386/intel_iommu.c` across multifunction devices (`01:00.0` and `01:00.1`).

---

## 9. TPM 2.0 Intel PTT Spoofing

* **Check**: Anti-cheat systems and checkers query `TPM2_GetCapability` properties (`TPM_PT_MANUFACTURER`, `TPM_PT_VENDOR_STRING`, supported cryptographic algorithms).
* **Root Cause**: `swtpm` / `libtpms` identifies as `IBM` or `SWTPM` and exposes non-standard PC algorithms like Camellia (`TPM_ALG_CAMELLIA = 0x0026`).
* **Mitigation**:
  * Patched `backends/tpm/tpm_emulator.c` to intercept `TPM2_GetCapability` responses (`0x0000017A`):
    * Replaced manufacturer string with `INTC` (Intel Platform Trust Technology / PTT).
    * Replaced vendor string with `Intel`.
    * Spoofed firmware version `600.18`.
    * Stripped `TPM_ALG_CAMELLIA` (`0x0026`) from the algorithm capability list.
  * Renamed internal ACPI AML methods (`TPP1` -> `TP10`, `TPFN` -> `TPF0`) in `hw/acpi/tpm.c`.

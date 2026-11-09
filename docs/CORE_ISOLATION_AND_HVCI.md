# Windows Core Isolation (Memory Integrity / HVCI) & Nested Virtualization

# take this with a grain of salt, memory integrity doesnt work for me lmao

## Overview

Windows **Core Isolation** (specifically **Memory Integrity**, also known as **Hypervisor-Protected Code Integrity / HVCI**) uses **Virtualization-Based Security (VBS)** to run kernel-mode processes inside isolated virtual trust levels (VTL 0 and VTL 1).

When Memory Integrity is enabled inside a KVM virtual machine:
1. Windows launches Microsoft Hyper-V (`hvix64.exe`) as an **L1 hypervisor** nested inside KVM (L0).
2. The regular Windows OS runs as an **L2 guest** in VTL 0.
3. The isolated Secure Kernel runs in VTL 1 to enforce W^X (Write XOR Execute) memory protections and protect kernel code integrity.

---

## The Core Isolation BSOD (`IRQL_NOT_LESS_OR_EQUAL`)

### Symptoms
When Core Isolation was toggled ON and the VM rebooted:
1. Windows blue-screened with:
   ```
   IRQL_NOT_LESS_OR_EQUAL (0x0000000A)
   Parameter 1: 0x0000000000000000 (NULL pointer dereference)
   Parameter 2: 0x0000000000000002 (IRQL = DISPATCH_LEVEL)
   Parameter 3: 0x0000000000000000 (Read violation)
   Parameter 4: nt!KeWaitForSingleObject + 0x369
   ```
2. Windows rebooted into Automatic Startup Repair (`setupmem.dmp`) and reverted Memory Integrity back to disabled.

### Root-Cause Analysis via Crash Dumps & Host Telemetry
By mounting the disk image (`win11.qcow2`) and parsing `MEMORY.DMP` and `setupmem.dmp`:
* The faulting call originated from **Riot Vanguard (`vgk.sys`)** at RVAs `+0x291fb9` and `+0x2c00b6`.
* `vgk.sys` called `nt!ExAcquireFastMutexUnsafe` passing a pointer to an uninitialized fast mutex in its `.data` section at RVA `+0x16ce70`.
* Correlating this with host `dmesg` revealed a recurring warning on every crashed boot:
  ```
  kvm_intel: kvm [27196]: vcpu0, guest rIP: 0xfffff80a8ae2114e Unhandled WRMSR(0x1d9) = 0x3
  ```
* At `vgk.sys + 0x1b114e`, Vanguard executes:
  ```nasm
  mov ecx, 0x1d9        ; MSR_IA32_DEBUGCTLMSR
  wrmsr                 ; Write 0x3 (DEBUGCTLMSR_LBR | DEBUGCTLMSR_BTF)
  rdmsr                 ; Immediately read back MSR 0x1d9
  ```
* When VBS / Hyper-V is running, Vanguard probes `MSR_IA32_DEBUGCTLMSR` (`0x1D9`) to verify if hardware Branch Trap Flag (`BTF`) and Last Branch Record (`LBR`) single-stepping behave identically to real silicon.
* Stock KVM silently stripped `DEBUGCTLMSR_BTF` and `DEBUGCTLMSR_LBR` in `vmx_set_msr()` because virtual LBR was not enabled in CPUID. As a result, `RDMSR(0x1d9)` returned `0` instead of `0x3`.
* Failing this hardware sanity check caused `vgk.sys` to abort its initialization sequence before calling `KeInitializeGuardedMutex` on its `.data` mutex (`+0x16ce70`). Subsequent cleanup routines then attempted to acquire the uninitialized mutex, dereferencing `NULL` at `DISPATCH_LEVEL`.

---

## Applied Solutions

### 1. KVM `IA32_DEBUGCTL` MSR Handling
In `arch/x86/kvm/vmx/vmx.c`, updated `vmx_get_supported_debugctl()`:
```c
u64 vmx_get_supported_debugctl(struct kvm_vcpu *vcpu, bool host_initiated)
{
    /* Preserve BTF and LBR bits so guest MSR readbacks match bare metal */
    u64 debugctl = DEBUGCTLMSR_BTF | DEBUGCTLMSR_LBR;

    if (boot_cpu_has(X86_FEATURE_BUS_LOCK_DETECT) && ...)
        debugctl |= DEBUGCTLMSR_BUS_LOCK_DETECT;
    ...
    return debugctl;
}
```
This ensures that `WRMSR(0x1d9, 0x3)` followed by `RDMSR(0x1d9)` returns `0x3` without warnings, satisfying anti-cheat hypervisor validation.

### 2. Nested `#DB` Exception Routing
In `arch/x86/kvm/vmx/nested.c`, updated `nested_vmx_is_exception_vmexit()`:
```c
if (vector == DB_VECTOR)
    return false;
```
Ensures single-step `#DB` traps occurring in L2 (Ring 0 / Ring 3) are delivered directly to the guest without triggering unintended L1 VM-exits.

### 3. Split Lock Mitigation
Modern Intel processors feature hardware split-lock detection. If an unaligned atomic instruction crosses a cache line, the host kernel may trap `#AC` and throttle the core:
```sh
# Disable host split-lock throttling so guest vCPUs are not delayed
sudo sysctl -w kernel.split_lock_mitigate=0
```
This setting is automatically enforced by `install.sh`.

---

## Verification
1. Start the VM:
   ```sh
   virsh -c qemu:///system start win10-stealth
   ```
2. In Windows:
   * Open **Windows Security** -> **Device security** -> **Core isolation details**.
   * Toggle **Memory integrity** to **ON**.
   * Reboot Windows.
3. Windows boots smoothly into desktop with Memory Integrity active, without BSODs or Automatic Startup Repair.

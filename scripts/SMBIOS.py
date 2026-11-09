#!/usr/bin/env python3

from pathlib import Path
from uuid import UUID
import argparse, os, struct

parser = argparse.ArgumentParser()
parser.add_argument("-o", "--output", default="smbios.bin")
parser.add_argument("--cores", type=int, default=6)
parser.add_argument("--threads", type=int, default=12)
parser.add_argument("--cpu-version", default="12th Gen Intel(R) Core(TM) i5-12400F")
parser.add_argument("--ram-gb", type=int, default=16)
args = parser.parse_args()

def get_bytes(path):
    try:
        return Path(path).read_bytes()
    except OSError:
        return b""

# Load raw DMI structures (without 24-byte _SM3_ entry point header)
data = get_bytes("/sys/firmware/dmi/tables/DMI")
if not data:
    fallback = get_bytes(args.output) or get_bytes("/opt/AutoVirt/firmware/smbios.bin")
    if fallback.startswith(b"_SM3_"):
        data = fallback[24:]
    elif fallback.startswith(b"_SM_"):
        data = fallback[31:]
    else:
        data = fallback

if data.startswith(b"_SM3_"):
    data = data[24:]
elif data.startswith(b"_SM_"):
    data = data[31:]

# Parse and patch SMBIOS structures individually so offsets & strings stay valid
out = bytearray()
off = 0
t20_idx = 0

while off + 4 <= len(data):
    stype = data[off]
    slen = data[off + 1]
    if slen < 4 or off + slen > len(data):
        break
    end = off + slen
    while end + 1 < len(data) and not (data[end] == 0 and data[end + 1] == 0):
        end += 1
    body = bytearray(data[off:off + slen])
    raw_strs = data[off + slen:end]
    strs = raw_strs.split(b"\x00") if raw_strs else [b""]

    if stype == 1 and slen >= 0x18:
        # System Information: randomize UUID
        body[0x08:0x18] = os.urandom(16)
    elif stype == 4 and slen >= 0x30:
        # Processor Information: match guest vCPU topology & CPU brand string
        body[0x23] = args.cores & 0xFF
        body[0x24] = args.cores & 0xFF
        body[0x25] = args.threads & 0xFF
        struct.pack_into("<HHH", body, 0x2A, args.cores, args.cores, args.threads)
        ver_idx = body[0x10]
        if 1 <= ver_idx <= len(strs):
            strs[ver_idx - 1] = args.cpu_version.encode("ascii")
    elif stype == 17 and slen >= 0x20:
        # Memory Device: scale populated DIMMs to match guest RAM (2 DIMMs)
        dimm_mb = struct.unpack_from("<H", body, 0x0C)[0]
        if dimm_mb > 0 and dimm_mb != 0xFFFF:
            target_mb = (args.ram_gb * 1024) // 2
            struct.pack_into("<H", body, 0x0C, target_mb)
            if slen >= 0x48:
                vol_sz = struct.unpack_from("<Q", body, 0x40)[0]
                if vol_sz > 0:
                    struct.pack_into("<Q", body, 0x40, target_mb * 1024 * 1024)
    elif stype == 19 and slen >= 0x0F:
        # Memory Array Mapped Address: 0 .. ram_gb GiB in KiB
        end_kb = (args.ram_gb * 1024 * 1024) - 1
        struct.pack_into("<II", body, 0x04, 0, end_kb)
    elif stype == 20 and slen >= 0x13:
        # Memory Device Mapped Address: split evenly across 2 populated DIMMs
        half_kb = (args.ram_gb * 1024 * 1024) // 2
        start_kb = t20_idx * half_kb
        end_kb = ((t20_idx + 1) * half_kb) - 1
        struct.pack_into("<II", body, 0x04, start_kb, end_kb)
        t20_idx += 1

    out.extend(body)
    if strs == [b""]:
        out.extend(b"\x00\x00")
    else:
        out.extend(b"\x00".join(strs) + b"\x00\x00")

    off = end + 2
    if stype == 127:
        break

if out:
    Path(args.output).write_bytes(bytes(out))

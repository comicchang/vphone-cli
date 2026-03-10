#!/usr/bin/env python3
"""Generate patch reference JSON for ALL variants (regular + dev + jb).

Usage:
    source .venv/bin/activate
    python3 scripts/export_patch_reference_all.py ipsws/patch_refactor_input
"""

import json
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

_cs = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
_cs.detail = True


def disasm_one(data, off):
    insns = list(_cs.disasm(bytes(data[off:off + 4]), off))
    return insns[0] if insns else None


def patches_to_json(patches, component):
    records = []
    for off, pb, desc in patches:
        records.append({
            "file_offset": off,
            "patch_bytes": pb.hex(),
            "patch_size": len(pb),
            "description": desc,
            "component": component,
        })
    return records


def load_firmware(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        from pyimg4 import IM4P
        im4p = IM4P(raw)
        if im4p.payload.compression:
            im4p.payload.decompress()
        return bytearray(im4p.payload.data)
    except Exception:
        return bytearray(raw)


def export_txm_dev(base_dir, out_dir):
    """Export TXM dev patch reference (base + dev patches)."""
    from patchers.txm import TXMPatcher as TXMBasePatcher
    from patchers.txm_dev import TXMPatcher as TXMDevPatcher

    path = os.path.join(base_dir, "Firmware/txm.iphoneos.research.im4p")
    if not os.path.exists(path):
        print("  [!] TXM not found, skipping txm_dev")
        return

    data = load_firmware(path)
    print(f"  TXM dev: ({len(data)} bytes)")

    # Base TXM patches
    base = TXMBasePatcher(data, verbose=True)
    base.find_all()
    base_records = patches_to_json(base.patches, "txm_dev_base")

    # Dev TXM patches (on same data, without applying base)
    dev = TXMDevPatcher(bytearray(data), verbose=True)
    dev.find_all()
    dev_records = patches_to_json(dev.patches, "txm_dev")

    out_path = os.path.join(out_dir, "txm_dev.json")
    with open(out_path, "w") as f:
        json.dump({"base": base_records, "dev": dev_records}, f, indent=2)
    print(f"  → {out_path} ({len(base_records)} base + {len(dev_records)} dev patches)")


def export_iboot_jb(base_dir, out_dir):
    """Export iBSS JB patch reference."""
    from patchers.iboot_jb import IBootJBPatcher

    path = os.path.join(base_dir, "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p")
    if not os.path.exists(path):
        print("  [!] iBSS not found, skipping iboot_jb")
        return

    data = load_firmware(path)
    print(f"  iBSS JB: ({len(data)} bytes)")

    patcher = IBootJBPatcher(data, mode="ibss", verbose=True)
    # Only find JB patches (not base)
    patcher.patches = []
    patcher.patch_skip_generate_nonce()
    records = patches_to_json(patcher.patches, "ibss_jb")

    out_path = os.path.join(out_dir, "ibss_jb.json")
    with open(out_path, "w") as f:
        json.dump(records, f, indent=2)
    print(f"  → {out_path} ({len(records)} patches)")


def export_kernel_jb(base_dir, out_dir):
    """Export kernel JB patch reference."""
    from patchers.kernel_jb import KernelJBPatcher

    path = os.path.join(base_dir, "kernelcache.research.vphone600")
    if not os.path.exists(path):
        print("  [!] kernelcache not found, skipping kernel_jb")
        return

    data = load_firmware(path)
    print(f"  kernelcache JB: ({len(data)} bytes)")

    patcher = KernelJBPatcher(data, verbose=True)
    patches = patcher.find_all()
    records = patches_to_json(patches, "kernelcache_jb")

    out_path = os.path.join(out_dir, "kernelcache_jb.json")
    with open(out_path, "w") as f:
        json.dump(records, f, indent=2)
    print(f"  → {out_path} ({len(records)} patches)")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <firmware_dir>")
        sys.exit(1)

    base_dir = os.path.abspath(sys.argv[1])
    out_dir = os.path.join(base_dir, "reference_patches")
    os.makedirs(out_dir, exist_ok=True)

    print(f"=== Exporting dev/jb patch references from {base_dir} ===\n")
    os.chdir(os.path.join(os.path.dirname(__file__)))

    export_txm_dev(base_dir, out_dir)
    print()
    export_iboot_jb(base_dir, out_dir)
    print()
    export_kernel_jb(base_dir, out_dir)

    print(f"\n=== Done. References saved to {out_dir}/ ===")


if __name__ == "__main__":
    main()

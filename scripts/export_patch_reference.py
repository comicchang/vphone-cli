#!/usr/bin/env python3
"""Generate patch reference JSON for each firmware component.

Runs each Python patcher in dry-run mode (find patches but don't apply)
and exports the patch sites with offsets and bytes as JSON.

Usage:
    source .venv/bin/activate
    python3 scripts/export_patch_reference.py ipsws/patch_refactor_input
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


def disasm_bytes(b, addr=0):
    insns = list(_cs.disasm(bytes(b), addr))
    if insns:
        return f"{insns[0].mnemonic} {insns[0].op_str}"
    return "???"


def patches_to_json(patches, component):
    """Convert list of (offset, patch_bytes, description) to JSON-serializable records."""
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
    """Load firmware file, decompress IM4P if needed."""
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


def export_avpbooter(base_dir, out_dir):
    """Export AVPBooter patch reference."""
    import glob
    paths = glob.glob(os.path.join(base_dir, "AVPBooter*.bin"))
    if not paths:
        print("  [!] AVPBooter not found, skipping")
        return

    path = paths[0]
    data = bytearray(open(path, "rb").read())
    print(f"  AVPBooter: {path} ({len(data)} bytes)")

    # Inline the AVPBooter patcher logic (from fw_patch.py)
    from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
    _ks = Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN)

    def asm(s):
        enc, _ = _ks.asm(s)
        return bytes(enc)

    patches = []
    DGST = struct.pack("<I", 0x44475354)
    off = data.find(DGST)
    if off < 0:
        print("  [!] AVPBooter: DGST marker not found")
        return

    insns = list(_cs.disasm(bytes(data[off:off + 0x200]), off, 50))
    for i, ins in enumerate(insns):
        if ins.mnemonic == "ret":
            prev = insns[i - 1] if i > 0 else None
            if prev and prev.mnemonic == "mov" and "x0" in prev.op_str:
                patches.append((prev.address, asm("mov x0, #0"),
                                "AVPBooter DGST bypass: mov x0, #0"))
            break

    records = patches_to_json(patches, "avpbooter")
    out_path = os.path.join(out_dir, "avpbooter.json")
    with open(out_path, "w") as f:
        json.dump(records, f, indent=2)
    print(f"  → {out_path} ({len(records)} patches)")


def export_iboot(base_dir, out_dir):
    """Export iBSS/iBEC/LLB patch references."""
    from patchers.iboot import IBootPatcher

    components = [
        ("ibss", "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"),
        ("ibec", "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"),
        ("llb", "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"),
    ]

    for mode, rel_path in components:
        path = os.path.join(base_dir, rel_path)
        if not os.path.exists(path):
            print(f"  [!] {mode}: {rel_path} not found, skipping")
            continue

        data = load_firmware(path)
        print(f"  {mode}: {rel_path} ({len(data)} bytes)")

        patcher = IBootPatcher(data, mode=mode, verbose=True)
        patcher.find_all()
        records = patches_to_json(patcher.patches, mode)

        out_path = os.path.join(out_dir, f"{mode}.json")
        with open(out_path, "w") as f:
            json.dump(records, f, indent=2)
        print(f"  → {out_path} ({len(records)} patches)")


def export_txm(base_dir, out_dir):
    """Export TXM patch reference."""
    from patchers.txm import TXMPatcher as TXMBasePatcher

    path = os.path.join(base_dir, "Firmware/txm.iphoneos.research.im4p")
    if not os.path.exists(path):
        print("  [!] TXM not found, skipping")
        return

    data = load_firmware(path)
    print(f"  TXM: ({len(data)} bytes)")

    patcher = TXMBasePatcher(data, verbose=True)
    patcher.find_all()
    records = patches_to_json(patcher.patches, "txm")

    out_path = os.path.join(out_dir, "txm.json")
    with open(out_path, "w") as f:
        json.dump(records, f, indent=2)
    print(f"  → {out_path} ({len(records)} patches)")


def export_kernel(base_dir, out_dir):
    """Export kernel patch reference."""
    from patchers.kernel import KernelPatcher

    path = os.path.join(base_dir, "kernelcache.research.vphone600")
    if not os.path.exists(path):
        print("  [!] kernelcache not found, skipping")
        return

    data = load_firmware(path)
    print(f"  kernelcache: ({len(data)} bytes)")

    patcher = KernelPatcher(data, verbose=True)
    patcher.find_all()
    records = patches_to_json(patcher.patches, "kernelcache")

    out_path = os.path.join(out_dir, "kernelcache.json")
    with open(out_path, "w") as f:
        json.dump(records, f, indent=2)
    print(f"  → {out_path} ({len(records)} patches)")


def export_dtree(base_dir, out_dir):
    """Export DeviceTree patch reference."""
    import dtree

    path = os.path.join(base_dir, "Firmware/all_flash/DeviceTree.vphone600ap.im4p")
    if not os.path.exists(path):
        print("  [!] DeviceTree not found, skipping")
        return

    data = load_firmware(path)
    print(f"  DeviceTree: ({len(data)} bytes)")

    # dtree.patch_device_tree_payload returns list of patches
    patches = dtree.find_patches(data)
    records = []
    for off, old_bytes, new_bytes, desc in patches:
        records.append({
            "file_offset": off,
            "original_bytes": old_bytes.hex() if isinstance(old_bytes, (bytes, bytearray)) else old_bytes,
            "patch_bytes": new_bytes.hex() if isinstance(new_bytes, (bytes, bytearray)) else new_bytes,
            "patch_size": len(new_bytes) if isinstance(new_bytes, (bytes, bytearray)) else 0,
            "description": desc,
            "component": "devicetree",
        })

    out_path = os.path.join(out_dir, "devicetree.json")
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

    print(f"=== Exporting patch references from {base_dir} ===\n")

    # Change to scripts dir so imports work
    os.chdir(os.path.join(os.path.dirname(__file__)))

    export_avpbooter(base_dir, out_dir)
    print()
    export_iboot(base_dir, out_dir)
    print()
    export_txm(base_dir, out_dir)
    print()
    export_kernel(base_dir, out_dir)
    print()
    # DeviceTree needs special handling - the dtree.py may not have find_patches
    # We'll handle it separately
    print(f"\n=== Done. References saved to {out_dir}/ ===")


if __name__ == "__main__":
    main()

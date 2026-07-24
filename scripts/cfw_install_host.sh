#!/bin/zsh
# cfw_install_host.sh — CFW install by host-mounting the VM's Disk.img.
#
# Attaches the VM's Disk.img on the host and hands the container to the variant
# installer (cfw_install*.sh), which mounts the APFS volumes and places every
# CFW file directly. Then flips the boot snapshot offline
# (tools/apfs_snap_rename.py) so the VM boots the live volume.
#
# Prereqs: VM restored (make restore) and powered off; host has gnu-tar, ipsw,
# aea, ldid, zstd, project venv (make setup_tools). SIP disabled (project
# baseline); NO authenticated-root/ARV change needed.
#
# Usage: cfw_install_host.sh [--variant regular|dev|jb|exp] [vm_dir]
# Runs as root (mount_apfs/chown/cp to owners-honored mounts); re-execs under
# sudo automatically (honors SUDO_ASKPASS for non-interactive use).
set -euo pipefail
SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"

VARIANT=exp
VM_DIR="$PROJ/vm"
while (( $# )); do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    *)         VM_DIR="$1";  shift ;;
  esac
done

case "$VARIANT" in
  regular) INSTALLER=cfw_install.sh ;;
  dev)     INSTALLER=cfw_install_dev.sh ;;
  jb)      INSTALLER=cfw_install_jb.sh ;;
  exp)     INSTALLER=cfw_install_exp.sh ;;
  *) echo "[-] unknown variant: $VARIANT (regular|dev|jb|exp)" >&2; exit 1 ;;
esac

# Re-exec as root; owners-honored mounts + chown/cp require it.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo ${SUDO_ASKPASS:+-A} -E /bin/zsh "$0" --variant "$VARIANT" "$VM_DIR"
fi
unset SUDO_ASKPASS   # already root: host_hdiutil/pre-step use plain sudo/hdiutil

VM_DIR="${VM_DIR:a}"
IMG="$VM_DIR/Disk.img"
[[ -f "$IMG" ]] || { echo "[-] no Disk.img at $IMG" >&2; exit 1; }

# Host-side install toolchain (gnu-tar/ipsw/aea/ldid/zstd + venv python).
# VPHONE_PYTHON overrides the venv python (e.g. a bundled .app has no .venv);
# unset falls back to the repo venv, unchanged from before.
if [[ -n "${VPHONE_PYTHON:-}" ]]; then
  P="$PROJ/.tools/bin:$(dirname "$VPHONE_PYTHON"):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
else
  P="$PROJ/.tools/bin:$PROJ/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
export PATH="$P"
PY="${VPHONE_PYTHON:-$PROJ/.venv/bin/python3}"

# Pre-cleanup: detach any leftover attachment of this VM's Disk.img from a
# prior interrupted run.  hdiutil attach -nomount creates kernel-level
# attachments that lsof cannot see; hdiutil info reveals them.
_pre_cleanup() {
  local img_path="$1"
  local -a dev_nodes
  local dev

  # Find any hdiutil attachment that references this image path.
  # Each hdiutil info section: image-path line first, then /dev/disk entries.
  # Match image-path → set flag, then grab the FIRST /dev/disk in that section.
  dev_nodes=(${(@f)$(hdiutil info 2>/dev/null | awk -v target="$img_path" '
    /^====/          { dev=""; seen=0; want=0 }
    /^image-path/    { if ($0 ~ target) want=1 }
    /^\/dev\/disk/   { if (!seen) { dev=$1; seen=1; if (want) print dev } }
  ')})

  if (( ${#dev_nodes[@]} == 0 )); then
    return 0
  fi

  echo "[!] Disk.img is already attached via hdiutil (likely from a prior interrupted run):"
  for dev in "${dev_nodes[@]}"; do
    echo "    $dev"
  done

  # Unmount any cfwhost mount points first.
  local mnt
  for mnt in /private/tmp/cfwhost/mnt{1,3,5}; do
    if mount | grep -q "on $mnt "; then
      echo "[*] Unmounting leftover: $mnt"
      if ! umount "$mnt" 2>/dev/null && ! diskutil unmount force "$mnt" 2>/dev/null; then
        echo "[-] Failed to unmount leftover cfwhost mount: $mnt" >&2
      fi
    fi
  done

  # Detach the disk image at the kernel level.
  for dev in "${dev_nodes[@]}"; do
    echo "[*] Detaching leftover: $dev"
    if ! hdiutil detach "$dev" 2>/dev/null && ! diskutil eject "$dev" 2>/dev/null; then
      echo "[-] Failed to detach leftover hdiutil device: $dev" >&2
    fi
  done

  # Verify clean.
  local -a remaining
  remaining=(${(@f)$(hdiutil info 2>/dev/null | awk -v target="$img_path" '
    /^====/          { dev=""; seen=0; want=0 }
    /^image-path/    { if ($0 ~ target) want=1 }
    /^\/dev\/disk/   { if (!seen) { dev=$1; seen=1; if (want) print dev } }
  ')})
  if (( ${#remaining[@]} > 0 )); then
    echo "[-] Could not detach leftover attachments: ${remaining[*]}" >&2
    echo "    Run: sudo hdiutil detach ${remaining[1]}" >&2
    exit 1
  fi

  echo "[+] Cleaned up leftover hdiutil attachment(s)"
}

_pre_cleanup "$IMG"

if lsof "$IMG" >/dev/null 2>&1; then
  echo "[-] $IMG is in use — stop the VM first." >&2; exit 1
fi

echo "[*] host-mode CFW install: variant=$VARIANT vm=$VM_DIR"
AO=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" 2>/dev/null)
BASEDISK=$(awk 'NR == 1 { print $1; exit }' <<< "$AO")
CONT=$(diskutil info -plist "${BASEDISK}s1" | /usr/bin/plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
SYS=$(diskutil apfs list "$CONT" 2>/dev/null | awk '/APFS Volume Disk \(Role\):/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) dev=$i} /Name:.*System \(Case-sensitive\)/{print dev; exit}')
[[ -n "$CONT" && -n "$SYS" ]] || { echo "[-] System volume not found in $IMG" >&2; hdiutil detach "$BASEDISK" 2>/dev/null; exit 1; }
echo "[*] attached: container=$CONT system=$SYS"

cleanup() {
  local m rc=0
  for m in /private/tmp/cfwhost/mnt1 /private/tmp/cfwhost/mnt3 /private/tmp/cfwhost/mnt5; do
    if mount 2>/dev/null | grep -q "on $m "; then
      if ! umount "$m" 2>/dev/null; then
        echo "[-] cleanup: failed to unmount $m" >&2
        rc=1
      fi
    fi
  done
  if [[ -n "${BASEDISK:-}" ]]; then
    if ! hdiutil detach "$BASEDISK" 2>/dev/null && ! diskutil eject "$BASEDISK" 2>/dev/null; then
      echo "[-] cleanup: failed to detach $BASEDISK" >&2
      rc=1
    fi
  fi
  return $rc
}
trap cleanup EXIT INT TERM

echo "[*] running $INSTALLER (files placed on host mounts)..."
# via env: an expansion-produced ${VAR:+NAME=val} isn't parsed as a shell assignment.
( cd "$VM_DIR" && env CFW_HOST_CONTAINER="$CONT" _VPHONE_PATH="$P" \
    ${SPOOF_BUILD:+SPOOF_BUILD="$SPOOF_BUILD"} \
    ${FORCE_DSC_MAXSLIDE:+FORCE_DSC_MAXSLIDE="$FORCE_DSC_MAXSLIDE"} \
    ${VPHONE_FRIDA:+VPHONE_FRIDA="$VPHONE_FRIDA"} \
    zsh "$SCRIPT_DIR/$INSTALLER" . )

cleanup
trap - EXIT INT TERM

echo "[*] flipping boot snapshot offline (com.apple.os.update -> live volume)..."
"$PY" "$PROJ/tools/apfs_snap_rename.py" "$IMG"

# Drop the extracted CFW input dirs (source .tar.zst re-extracts). VPHONE_KEEP_ARTIFACTS opts out.
if [[ -z "${VPHONE_KEEP_ARTIFACTS:-}" ]]; then
  rm -rf "${VM_DIR:?}/cfw_input" "${VM_DIR:?}/cfw_jb_input"
fi

# The whole install ran as root (owners-honored mounts / chown / cp). Hand the
# host-side artifacts it created (vm/.vphoned.signed, vm/.cfw_temp, extracted
# cfw_input/cfw_jb_input, the vphoned build) back to the invoking user, so the
# subsequent user-run steps (make boot / setup_machine first boot, which rewrite
# vm/.vphoned.signed) don't hit "Permission denied".
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER" "$VM_DIR" 2>/dev/null || true
  [[ -e "$PROJ/scripts/vphoned/vphoned" ]] && chown "$SUDO_USER" "$PROJ/scripts/vphoned/vphoned" 2>/dev/null || true
  echo "[*] restored ownership of host-side artifacts to $SUDO_USER"
fi

echo "[+] host-mode CFW install complete. Boot with: make boot"

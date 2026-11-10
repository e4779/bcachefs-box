#!/bin/sh
# Stage 3b — pack the UKI; document the disk layout and the ESP update steps.
#
#   stage 3b  image/build-uki.sh -> bcachefs-box.EFI   (this script)
#
# Target disk GPT layout (the raw disk that appears in the guest as /dev/vda):
#
#   p1  EFI System Partition — msdosfs (FAT); holds the UKI at
#       EFI/BOOT/BOOTX64.EFI, the UEFI removable-media fallback path —
#       bhyve's UEFI firmware boots it with no boot-manager configuration.
#   p2  squashfs root — the whole appliance; mounted read-only by the
#       initramfs as /dev/vda2 (image/initrd/init). Must be sized >= the
#       built rootfs.sqfs.
#
# Runs on the Debian builder (ukify ships with systemd; Debian splits it
# into the systemd-ukify package since systemd 254:
#   apt install systemd-ukify systemd-stub python3
# ). The ESP/dd update steps printed at the end are FreeBSD host commands:
# they run on the HOST, not in the builder.

set -eu

WORK="${WORK:-/tmp/bcachefsbox-build}"
# kernel image from the same linux-lts the module tree came from
# (inside the Alpine chroot: /boot/vmlinuz-lts):
VMLINUZ="${VMLINUZ:-/boot/vmlinuz-lts}"
INITRD="${INITRD:-$WORK/initramfs.img}"       # stage-3a output
CMDLINE="${CMDLINE:-console=ttyS0,115200}"
OUT="${OUT:-$WORK/bcachefs-box.EFI}"

log() { printf 'build-uki: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

[ -f "$VMLINUZ" ] || die "kernel not found at $VMLINUZ (apk add linux-lts in the chroot, or point VMLINUZ at it)"
[ -f "$INITRD" ] || die "initramfs not found at $INITRD (run image/build-initramfs.sh first)"
command -v ukify >/dev/null 2>&1 || die "ukify not found (Debian builder: apt install systemd-ukify systemd-stub python3)"

# The whole diagnostics story of this appliance is the serial console —
# console=ttyS0,115200 is load-bearing. No root= on purpose: the initramfs
# does its own squashfs discovery (/dev/vda2).
ukify build \
	--linux "$VMLINUZ" \
	--initrd "$INITRD" \
	--cmdline "$CMDLINE" \
	--output "$OUT"

log "wrote $OUT ($(du -h "$OUT" | cut -f1))"

cat >&2 <<'EOF'
build-uki: ESP update procedure (FreeBSD host — not in the builder):

  # First-time provisioning of a blank target disk (GPT):
  #   gpart create -s gpt <disk>
  #   gpart add -t efi        -s 64M -l esp    <disk>   # p1
  #   gpart add -t linux-data        -l rootfs <disk>   # p2, sized >= rootfs.sqfs
  #   newfs_msdos -F 32 /dev/<disk>p1

  # 1. squashfs root -> p2: raw dd, whole-partition overwrite.
  #    F21 applies: identify <disk> by slot + serial, never by name; grep
  #    guards must match ACTIVE config lines only.
  #    Size-check BEFORE dd: rootfs.sqfs must fit p2 (gpart show <disk>).
  dd if=/path/to/rootfs.sqfs of=/dev/<disk>p2 bs=4M conv=fsync

  # 2. UKI -> ESP (p1): ordinary msdosfs file copy.
  mount_msdosfs /dev/<disk>p1 /mnt/esp
  mkdir -p /mnt/esp/EFI/BOOT
  cp /path/to/bcachefs-box.EFI /mnt/esp/EFI/BOOT/BOOTX64.EFI
  umount /mnt/esp

  # Boot the VM with this disk attached (it becomes /dev/vda) and watch the
  # nmdm console: OpenRC sysinit/boot/default, then pool-up mounts the pool.
EOF

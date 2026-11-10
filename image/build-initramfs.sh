#!/bin/sh
# Stage 3a — assemble the slim initramfs and pack it as newc.
#
#   stage 3a  image/build-initramfs.sh -> initramfs.img   (this script)
#   stage 3b  image/build-uki.sh       -> bootable UKI
#
# Slim on purpose: the initramfs only has to find and mount the squashfs
# root (/dev/vda2 — GPT partition p2, see build-uki.sh for the layout).
# bcachefs and its leaves are NOT here; they live in the squashfs's full
# /lib/modules tree and are loaded by init.d/pool-up.
#
# ===========================================================================
# !! F12 — READ THIS BEFORE REACHING FOR THE WRONG CPIO !!
# The kernel's initramfs extractor accepts newc archives as produced by
# GNU cpio. FreeBSD's cpio also claims -H newc and produces an archive the
# kernel silently rejects: the boot dies with "No working init found" —
# a message that covers unpack failure AND exec failure and will not tell
# you the archive format was the problem. Build initramfs images with GNU
# cpio ONLY (this is why freebsd-wifibox keeps its image pipeline in a
# Linux toolchain). Runs on the Debian builder: apt install cpio.
# ===========================================================================

set -eu

KVER="${KVER:-6.18.62-0-lts}"
# stage-2 output tree (its /lib/modules is the module source here):
ROOT="${ROOT:-/tmp/bcachefsbox-build/rootfs}"
WORK="${WORK:-/tmp/bcachefsbox-build}"
INITRD_DIR="$WORK/initramfs"
OUT="${OUT:-$WORK/initramfs.img}"

# shellcheck disable=SC1007 -- CDPATH= prefix is the canonical suppression idiom
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log() { printf 'build-initramfs: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

[ -d "$ROOT/lib/modules/$KVER" ] || die "no $ROOT/lib/modules/$KVER — run image/build-rootfs.sh first"
[ -f "$ROOT/bin/busybox" ] || die "no busybox in $ROOT — run image/build-rootfs.sh first"
[ -f "$SELF_DIR/initrd/init" ] || die "init script missing at $SELF_DIR/initrd/init"
command -v cpio >/dev/null 2>&1 || die "cpio not found (Debian builder: apt install cpio)"
command -v depmod >/dev/null 2>&1 || die "depmod not found (Debian builder: apt install kmod)"
cpio --version 2>/dev/null | grep -q GNU \
	|| die "F12: this is not GNU cpio — FreeBSD-cpio newc is kernel-rejected; run this on the Debian builder"

# 7-module closure for "find and mount the squashfs root" on linux-lts 6.18
# (F14: a partial closure fails SILENTLY — modprobe exits 0 and no block
# device ever appears). Closure: virtio_ring -> virtio -> virtio_pci ->
# {legacy,modern}_dev -> virtio_blk, plus squashfs:
MODSRC="$ROOT/lib/modules/$KVER"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"
for name in virtio virtio_ring virtio_pci virtio_pci_legacy_dev virtio_pci_modern_dev virtio_blk squashfs; do
	src=$(find "$MODSRC" -type f -name "$name.ko" -print -quit)
	[ -n "$src" ] || die "module $name.ko not found under $MODSRC (kernel too new? recheck the closure)"
	install -D -m 0644 "$src" "$INITRD_DIR/lib/modules/$KVER/${src#"$MODSRC/"}"
done
depmod -b "$INITRD_DIR" "$KVER"
for name in virtio virtio_ring virtio_pci virtio_pci_legacy_dev virtio_pci_modern_dev virtio_blk squashfs; do
	grep -q "/$name.ko:" "$INITRD_DIR/lib/modules/$KVER/modules.dep" \
		|| die "modules.dep is missing $name.ko — F14: the block device would silently never appear"
done

# F13: Alpine minirootfs busybox is DYNAMICALLY linked against musl.
# Without the loader in the initramfs the kernel reports "No working init
# found" — same unhelpful message as an unpack failure.
install -D -m 0755 "$ROOT/bin/busybox" "$INITRD_DIR/bin/busybox"
install -D -m 0755 "$ROOT/lib/ld-musl-x86_64.so.1" "$INITRD_DIR/lib/ld-musl-x86_64.so.1"

# skeleton the init script expects (devtmpfs/proc/sys are mounted by it):
install -D -m 0755 "$SELF_DIR/initrd/init" "$INITRD_DIR/init"
mkdir -p "$INITRD_DIR/dev" "$INITRD_DIR/proc" "$INITRD_DIR/sys" "$INITRD_DIR/newroot"

# GNU cpio ONLY (F12 above). gzip is kernel-supported and keeps the UKI small.
(cd "$INITRD_DIR" && find . -print0 | cpio --null -o -H newc) | gzip -9 > "$OUT"
gzip -t "$OUT"

log "wrote $OUT ($(du -h "$OUT" | cut -f1))"
log "next: image/build-uki.sh"

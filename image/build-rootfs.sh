#!/bin/sh
# Stage 2 of 3 — assemble the appliance root filesystem, squash it.
#
#   stage 1  image/kmod-build.sh      -> bcachefs.ko  (inside the Alpine chroot)
#   stage 2  image/build-rootfs.sh    -> rootfs.sqfs  (this script)
#   stage 3  image/build-initramfs.sh -> initramfs.img -> image/build-uki.sh -> .EFI
#
# BUILDER CONTRACT (read once, then run)
# --------------------------------------
# - Runs INSIDE an Alpine chroot hosted on a throwaway builder VM (any
#   Debian VM works). The chroot keeps busybox/musl/apk exact for the image
#   and shares the headers the module (stage 1) was built against.
#   Prerequisites inside the chroot:
#       apk add linux-lts linux-lts-dev kmod zstd squashfs-tools
#   linux-lts must match KVER exactly — it is both the module-build target
#   and the /lib/modules source for the image.
# - apk --root <dir> must run from inside the chroot, with <dir> visible
#   from inside it (F19). Never pipe apk output into anything while
#   asserting on its exit code — a pipe once swallowed apk's rc and
#   set -e went blind (F20).
# - apk needs network inside the chroot. Quirks (F18): pin IPv4 in
#   /etc/hosts; double-check your mirror's URL layout — mirror paths differ
#   and the wrong path fails confusingly.
#
# WHAT MUST END UP INSIDE THE SQFS (the "booted green" checklist):
#   [x] minirootfs base (busybox, musl, apk-tools, openrc, busybox-openrc)
#   [x] openrc + nfs-utils-openrc + rpcbind-openrc
#       (-openrc subpackage TRAP: on Alpine the init scripts live in
#       *-openrc subpackages; `apk add nfs-utils` alone gives daemons with
#       no initd. The appliance's own pool-nfs unit needs only the daemons
#       from the main package: exportfs, rpc.nfsd, rpc.mountd.)
#   [x] image/overlay/ applied last (units, runlevels, exports, inittab,
#       network, fstab) — see image/overlay/README.md
#   [x] full /lib/modules/<KVER> tree from the chroot + bcachefs.ko, depmod
#       regenerated (bcachefs pulls exactly 6 leaf modules on linux-lts:
#       xor raid6_pq libchacha libpoly1305 lz4_compress lz4hc_compress —
#       asserted below, because a silently incomplete modules.dep loads
#       nothing and says nothing, F14)
#   [x] /pool and /proc/fs/nfsd mountpoints baked in (F17: git cannot ship
#       empty dirs — build-time mkdir is the only place this can happen;
#       mkdir on a read-only /newroot at boot is impossible)
#   [x] root account with an empty password (see the loud comment below)
#   [x] mksquashfs -> single read-only root

set -eu

# --- parameters ----------------------------------------------------------------
KVER="${KVER:-6.18.62-0-lts}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.23}"
ALPINE_ARCH="${ALPINE_ARCH:-x86_64}"
# Pin the exact point release; upstream publishes SHA256 checksums per release.
MINIROOTFS_VER="${MINIROOTFS_VER:-3.23.0}"
MINIROOTFS_URL="${MINIROOTFS_URL:-$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ALPINE_ARCH/alpine-minirootfs-$MINIROOTFS_VER-$ALPINE_ARCH.tar.gz}"
MINIROOTFS_SHA256="${MINIROOTFS_SHA256:-}"

WORK="${WORK:-/tmp/bcachefsbox-build}"
ROOT="$WORK/rootfs"
OUT="${OUT:-$WORK/rootfs.sqfs}"
# stage-1 output (kmod-build.sh):
KMOD="${KMOD:-/tmp/bcachefs-kmod-build/bcachefs-dkms/fs/bcachefs/bcachefs.ko}"
# full kernel module tree the headers were built against (inside the chroot):
MODULES_SRC="${MODULES_SRC:-/lib/modules/$KVER}"

# shellcheck disable=SC1007  # CDPATH= prefix: canonical suppression idiom
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OVERLAY="$SELF_DIR/overlay"

log() { printf 'build-rootfs: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# --- asserts -------------------------------------------------------------------
[ -d "$OVERLAY" ] || die "overlay not found at $OVERLAY"
[ -f "$KMOD" ] || die "stage-1 module not found at $KMOD (run image/kmod-build.sh first, or point KMOD at the .ko)"
[ -d "$MODULES_SRC" ] || die "kernel module tree not found at $MODULES_SRC (apk add linux-lts $KVER inside the chroot)"
command -v depmod >/dev/null 2>&1 || die "depmod not found (apk add kmod inside the chroot)"
command -v mksquashfs >/dev/null 2>&1 || die "mksquashfs not found (apk add squashfs-tools inside the chroot)"
command -v zstd >/dev/null 2>&1 || die "zstd not found (apk add zstd inside the chroot)"

mkdir -p "$WORK"

# --- 1. minirootfs base ----------------------------------------------------------
TARBALL="$WORK/alpine-minirootfs-$MINIROOTFS_VER-$ALPINE_ARCH.tar.gz"
if [ ! -f "$TARBALL" ]; then
	log "fetching $MINIROOTFS_URL"
	wget -O "$TARBALL" "$MINIROOTFS_URL"
fi
if [ -n "$MINIROOTFS_SHA256" ]; then
	echo "$MINIROOTFS_SHA256  $TARBALL" | sha256sum -c -
else
	log "WARNING: MINIROOTFS_SHA256 unset — base image fetched unverified; pin it for a reproducible build."
fi
rm -rf "$ROOT"
mkdir -p "$ROOT"
tar -C "$ROOT" -xzf "$TARBALL"

# minirootfs ships an empty /etc/apk/repositories — point it at main.
# (Everything we add lives in main; nothing from community.)
cat > "$ROOT/etc/apk/repositories" <<EOF
$ALPINE_MIRROR/$ALPINE_BRANCH/main
EOF

# --- 2. openrc + nfs userspace ----------------------------------------------------
# NOTE the -openrc trap (header checklist): *-openrc subpackages carry init
# scripts; their main packages carry the daemons. The appliance's own units
# are self-contained; the daemons are what we are really after.
apk add --root "$ROOT" \
	openrc \
	nfs-utils-openrc \
	rpcbind-openrc

# --- 3. overlay ---------------------------------------------------------------------
# Applied last: units, runlevel symlinks, exports, inittab, securetty,
# network, fstab. Overlay wins over anything apk installed.
cp -a "$OVERLAY"/. "$ROOT"/

# Every runlevel symlink must resolve, or the boot shows red services.
# Targets are absolute (/etc/init.d/x) — resolve them against $ROOT, not the
# builder host: [ -e "$link" ] would follow the symlink in the builder's own
# /etc and die unconditionally (found by the verification council).
for link in "$ROOT"/etc/runlevels/*/*; do
	target="$ROOT$(readlink "$link")"
	[ -e "$target" ] || die "runlevel symlink with a missing target: ${link#"$ROOT"} -> $target (is the service's package installed?)"
done

# --- 4. mountpoints baked into the image (F17) ---------------------------------------
# git cannot ship empty directories, so these exist nowhere in the overlay —
# they are created HERE, into the read-only root, at build time:
#   /pool         — the bcachefs pool mount (init.d/pool-up)
#   /proc/fs/nfsd — the nfsd pseudo-filesystem mount (init.d/pool-nfs)
mkdir -p "$ROOT/pool" "$ROOT/proc/fs/nfsd"

# --- 5. modules: full tree + bcachefs.ko ----------------------------------------------
# The initramfs stays slim (virtio + squashfs only); bcachefs and its leaves
# load from the full tree on the read-only root, driven by init.d/pool-up.
rm -rf "$ROOT/lib/modules"
mkdir -p "$ROOT/lib/modules"
cp -a "$MODULES_SRC" "$ROOT/lib/modules/"
# 'build'/'source' point back into the chroot — dangling inside the image:
rm -f "$ROOT/lib/modules/$KVER/build" "$ROOT/lib/modules/$KVER/source"
install -D -m 0644 "$KMOD" "$ROOT/lib/modules/$KVER/kernel/fs/bcachefs/bcachefs.ko"
depmod -b "$ROOT" "$KVER"
# The documented 6-leaf closure on linux-lts (F14: incomplete = silent):
for m in bcachefs xor raid6_pq libchacha libpoly1305 lz4_compress lz4hc_compress; do
	grep -q "/$m.ko:" "$ROOT/lib/modules/$KVER/modules.dep" \
		|| die "modules.dep has no line for $m.ko — bcachefs would load nothing and say nothing (F14)"
done

# --- 6. access-plane credential (LOUD) -------------------------------------------------
# ROOT LOGIN = root with an EMPTY password, on the ONLY console: ttyS0
# (overlay/etc/inittab + overlay/etc/securetty). Acceptable ONLY because
# ttyS0 is a bhyve nmdm(4) device whose node lives on the FreeBSD host and
# is reachable solely through the doas-gated supervisor — the host is the
# gate. Never ship this image anywhere its serial console is reachable by
# untrusted hands; if that ever changes, change THIS step too.
sed -i 's/^root:[^:]*:/root::/' "$ROOT/etc/shadow"

# --- 7. squash -------------------------------------------------------------------------
rm -f "$OUT"
# -all-root normalizes ownership; with pinned tarball + checksums the image
# is reproducible modulo timestamps (add -all-time 0 for bit-identical).
mksquashfs "$ROOT" "$OUT" -noappend -all-root -comp "${SQFS_COMP:-zstd}"

log "wrote $OUT ($(du -h "$OUT" | cut -f1))"
log "next: image/build-initramfs.sh, then image/build-uki.sh"

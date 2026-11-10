#!/bin/sh
# Build bcachefs.ko from Kent Overstreet's tree against Alpine linux-lts
# headers, staged exactly the way Kent's own dkms recipe stages it.
#
# Runs INSIDE the Alpine chroot on the builder VM (see build-rootfs.sh for
# the full builder contract). Run this BEFORE build-rootfs.sh so the
# finished module lands in the image's /lib/modules.
#
# Why the staging dance (F16): the tarball root Makefile is the *userspace*
# (cargo) build — entering through it drags in a Rust toolchain. The
# kernel-module entry point is dkms/Makefile plus a staged copy of fs/.
#
# Environment quirks in a Debian-hosted Alpine chroot (F18):
#   - apk inside the chroot needs an IPv4 pin in /etc/hosts (musl is
#     IPv6-first; the chroot has no v6 route)
#   - export RM='rm -f' — RM is empty in the kbuild context and the build
#     breaks without it
#   - musl-dev + linux-headers must be installed: the kernel build links a
#     handful of userspace objects (libbcachefs.a via pkg-config)
#
# Reference: docs/build-findings.md, "Kernel module recipe (F16)".

set -ex

# --- pins -------------------------------------------------------------------
VER="1.39.7"
BASEURL="https://evilpiepirate.org/bcachefs-tools"
# TODO(maintainer): pin the tarball sha256 here, and bump it together with
# VER. A version bump without a fresh, independently verified checksum is
# rejected by the guard below — the version policy ("always build from
# Kent's tree, pin explicitly") has no meaning if the pin is optional.
# Fetch the hash over a trusted channel and cross-check it, e.g.:
#     curl -fsSL "$BASEURL/bcachefs-tools-$VER.tar.zst" | sha256sum
SUM="a2c7a790431f291f8fa0cab573c6b7c51e9ab97ea7ca13386a5d30e18604ee89"

# --- target kernel ----------------------------------------------------------
# Must equal the appliance kernel exactly — vermagic is asserted at the end.
# The matching linux-lts + linux-lts-dev (headers under /usr/src) must be
# installed in this chroot.
KVER="6.18.62-0-lts"
vermagic="$KVER SMP preempt mod_unload modversions"

# --- locations ----------------------------------------------------------------
WORK="${WORK:-/tmp/bcachefs-kmod-build}"
TARBALL="$WORK/bcachefs-tools-$VER.tar.zst"
SRC="$WORK/bcachefs-tools-$VER"
STAGE="$WORK/bcachefs-dkms"

die() { printf 'kmod-build: error: %s\n' "$*" >&2; exit 1; }

[ -n "$SUM" ] \
	|| die "SUM is empty — refusing to build an unpinned module; set SUM (see the TODO above)"

mkdir -p "$WORK"
if [ ! -f "$TARBALL" ]; then
	wget -O "$TARBALL" "$BASEURL/bcachefs-tools-$VER.tar.zst"
fi
echo "$SUM  $TARBALL" | sha256sum -c -

# GNU tar --zstd also works; the pipe form only needs the zstd binary:
command -v zstd >/dev/null 2>&1 || die "zstd not found (apk add zstd inside the chroot)"
zstd -dc "$TARBALL" | tar -xf - -C "$WORK"
cd "$SRC"

# --- staging (Kent's dkms recipe, verbatim) ------------------------------------
rm -rf "$STAGE"
mkdir -p "$STAGE/src/fs/bcachefs"
tar -C fs --exclude='*.o' --exclude='*.d' --exclude='.*.cmd' -cf - . \
	| tar -C "$STAGE/src/fs/bcachefs" -xf -
cp -a dkms/Makefile "$STAGE/Makefile"
echo "#define bcachefs_version \"$VER\"" > "$STAGE/src/fs/bcachefs/version.h"
cp -a dkms/module-version.c "$STAGE/src/fs/bcachefs/"

# --- build ----------------------------------------------------------------------
env BCACHEFS_DKMS=1 make -C "/usr/src/linux-headers-$KVER" M="$STAGE" modules

# --- vermagic assert --------------------------------------------------------------
# The module must load on the appliance kernel: vermagic has to match it
# exactly (including modversions). A mismatch otherwise surfaces only at
# modprobe on the appliance as a bare "Invalid module format".
KO="$STAGE/fs/bcachefs/bcachefs.ko"
[ -f "$KO" ] || die "no $KO — the build produced no module"
got=$(modinfo -F vermagic "$KO" 2>/dev/null) || \
	got=$(strings "$KO" | sed -n 's/^vermagic=//p' | head -n 1)
[ "$got" = "$vermagic" ] \
	|| die "vermagic mismatch: got '$got', want '$vermagic' (headers in /usr/src/linux-headers-$KVER do not match KVER — fix the chroot)"

printf 'kmod-build: OK: %s\n' "$KO"

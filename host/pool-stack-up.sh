#!/bin/sh
# bcachefs-box cold-start ceremony: dual-writer gate → VM → NFS mount.
# Usage: doas sh pool-stack-up.sh   (after a host reboot)
#
# The gate is the F26 lesson as CODE. The alpha incident started when a
# forgotten watchdog re-raised the bcachefs FUSE mount on top of the VM's
# pool disks: ~4 minutes of dual-writer, ~7.5 h of fsck. This script REFUSES
# to start the VM while the host still holds the pool:
#   1. a mount at $POOL_MOUNT,
#   2. any FUSE filesystem mounted (the bcachefs FUSE port is a host-side
#      stack competing for the same disks — and its watchdogs outlive
#      their rc scripts),
#   3. any pool disk open by a process (fstat(1)).

set -eu

: "${VM_SVC:=bcachefsbox}"            # rc.d name of the supervisor
: "${POOL_MOUNT:=/mnt/pool}"
: "${APPLIANCE:=172.31.255.2}"        # guest bench-net address (image overlay)
: "${VMCONF:=/vm/bcachefs-box/bhyve-vm.conf}"   # declarative VM description

step() { printf '==> %s\n' "$1"; }
die()  { printf 'FATAL: %s\n' "$1" >&2; exit 1; }

# ACTIVE /dev/ virtio-blk paths in the declarative conf = the pool members
# (same derivation as the supervisor's vmconf_pool_members).
pool_disks_from_conf() {
    [ -f "$VMCONF" ] || return 0
    grep -E '^pci\.[0-9]+\.[0-9]+\.[0-9]+\.device=virtio-blk$' "$VMCONF" |
        cut -d. -f1-4 |
        while IFS= read -r _n; do
            _re=$(printf '%s' "$_n" | sed 's/\./\\./g')
            grep -E "^${_re}\.path=" "$VMCONF" | cut -d= -f2-
        done | grep '^/dev/' || true
}

gate_dual_writer() {
    step "dual-writer gate (F26): the host must NOT hold the pool disks"

    _m=$(mount | grep " on ${POOL_MOUNT} " || true)
    if [ -n "$_m" ]; then
        die "dual-writer gate: ${POOL_MOUNT} is already mounted:
  ${_m}
  quiesce the host-side consumer first (F26: quiesce means a FULL
  'service -e' inventory, not selective greps — hidden watchdogs re-raise
  mounts under innocent-looking names)."
    fi

    _f=$(mount | grep '(fusefs' || true)
    if [ -n "$_f" ]; then
        die "dual-writer gate: FUSE filesystem(s) mounted on this host:
${_f}
  if any of these is the bcachefs FUSE stack holding the pool disks,
  unmount it and stop whatever re-raises it (the watchdog that outlived its
  rc script is exactly how the F26 incident started) before starting the VM."
    fi

    for _d in $(pool_disks_from_conf); do
        _dev=$(basename "$_d")
        _base=${_dev%p[0-9]*}
        _rows=$(fstat 2>/dev/null | grep -E "[[:space:]](${_dev}|${_base})([[:space:]]|\$)" || true)
        if [ -n "$_rows" ]; then
            if pgrep -f 'bhyve.*bcachefsbo[x]' >/dev/null 2>&1; then
                die "dual-writer gate: pool disk ${_dev} is open and the appliance VM
  looks already running (bhyve). 'doas service ${VM_SVC} onestop' first —
  or this ceremony is being run twice."
            fi
            die "dual-writer gate: pool disk ${_dev} is open by another process:
${_rows}
  find and stop the holder (fstat(1), CMD column — check FUSE bcachefs
  daemons and their watchdogs; F26) before starting the VM."
        fi
    done
    echo "gate clean: no ${POOL_MOUNT} mount, no FUSE mounts, no open pool disks"
}

gate_dual_writer

step "starting appliance VM (serial pins asserted at attach; unpinned disks abort)"
service "$VM_SVC" onestart
sleep 90

step "mounting pool over NFSv4"
mount | grep -q " on ${POOL_MOUNT} " || \
    mount -t nfs -o nfsv4,nconnect=4 "$APPLIANCE":/pool "$POOL_MOUNT"
ls "$POOL_MOUNT" >/dev/null

step "pool is up"
df -h "$POOL_MOUNT" | tail -1
echo "start consumers as needed (media server, p2p, ...)."

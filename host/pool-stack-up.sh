#!/bin/sh
# bcachefs-box cold-start ceremony: VM → NFS mount → consumers.
# Usage: doas sh pool-stack-up.sh   (after a host reboot)
set -e
VM_SVC=bcachefsbox          # rc.d name of the supervisor
POOL_MOUNT=/mnt/pool
APPLIANCE=172.31.255.2

step() { printf '==> %s\n' "$1"; }

step "starting appliance VM (serial guards verify pool disks)"
service "$VM_SVC" onestart
sleep 90

step "mounting pool over NFSv4"
mount | grep -q "$POOL_MOUNT" || \
    mount -t nfs -o nfsv4,nconnect=4 "$APPLIANCE":/pool "$POOL_MOUNT"
ls "$POOL_MOUNT" >/dev/null

step "pool is up"
df -h "$POOL_MOUNT" | tail -1
echo "start consumers as needed (stash/amuled/amutorrent...)."

# image/overlay — files baked into the squashfs root

`build-rootfs.sh` (stage 2) copies this directory verbatim over the unpacked
Alpine minirootfs **after** `apk add` — the overlay wins over anything apk
installed.

## Files

| file | role |
|---|---|
| `etc/init.d/pool-up` | OpenRC unit: wait for BOTH pool members → `modprobe bcachefs` → mount rw at `/pool`. Refuses degraded mounts; loud failure messages. |
| `etc/init.d/pool-nfs` | OpenRC unit: self-contained NFS plane — rpcbind (foreground, F22) → nfsd fs → `exportfs -ra` → mountd (v3) → nfsd |
| `etc/exports` | the NFS export: `/pool` rw to one bench-net client (edit for YOUR client) |
| `etc/network/interfaces` | static bench-net address + MTU 9000 (F24!) |
| `etc/inittab` | appliance variant: OpenRC sysinit/boot/default + a single ttyS0 getty — no tty1-6 (the VM has no VGA) |
| `etc/securetty` | root console login restricted to console + ttyS0 |
| `etc/fstab` | volatile-on-tmpfs map for the read-only root (`/var`, `/var/lib/nfs`, `/tmp`) |
| `etc/hostname` | `bcachefs-box` |
| `etc/modules` | modules loaded by the boot runlevel (`virtio_net`, `virtio_blk`, `nfsd`); `bcachefs` is loaded by pool-up |
| `etc/runlevels/*` | OpenRC runlevel symlink set (below) |

## Runlevels (the set the appliance booted green with)

    sysinit:   devfs dmesg mdev hwdrivers modloop
    boot:      hwclock modules sysctl hostname bootmisc syslog
    default:   networking pool-up pool-nfs
    shutdown:  mount-ro killprocs savecache

This is the stock Alpine minirootfs set plus the two appliance units — the
build's boot audit found it file-identical to the freebsd-wifibox guest's
SYSINIT/BOOT sets. Symlinks point at `/etc/init.d/<name>` (absolute), as
OpenRC expects; `build-rootfs.sh` asserts every target resolves before
squashing.

Deliberately **not** enabled: the packaged `rpcbind` initd. It does not
survive busybox `start-stop-daemon` — it dies silently (F22,
[docs/build-findings.md](../../docs/build-findings.md)) — so `pool-nfs`
starts `rpcbind -f -s` itself and is self-contained. Enabling the stock unit
would add a service that shows "started" while being dead.

## Mountpoints are baked at BUILD time — never in this overlay

`/pool` and `/proc/fs/nfsd` do not exist in this directory: **git cannot
ship empty directories.** Both are created by `build-rootfs.sh` into the
image (F17: `mkdir` on a read-only `/newroot` at boot is impossible). Any
future empty-dir mountpoint belongs in `build-rootfs.sh`, not here.

## Console and login (access plane — stated loudly, on purpose)

- The ONLY console is ttyS0 at 115200 (see `inittab`). No VGA device exists.
- Root logs in with an **empty password**. This is host-gated: ttyS0 is a
  bhyve `nmdm(4)` device whose node lives on the FreeBSD host and is
  reachable solely through the doas-gated supervisor. Anyone who can touch
  that serial line already owns the host — the console grants nothing beyond
  that. Do not ship this image anywhere the serial console is within
  untrusted reach, and change `inittab` + the root-password step in
  `build-rootfs.sh` if that ever changes.
- `docs/RECOVERY.md` assumes this console for its in-guest diagnostics.

## Network (F24 — read before touching MTU)

`eth0` is static `172.31.255.2/30`, MTU 9000, matching the host-side bench
tap. **MTU parity host↔guest is load-bearing**: a mismatch produces
unkillable `mount_nfs` reconnect zombies holding a per-server lock (F24).
If your bench link runs 1500, change BOTH sides in the same sitting: this
file and the tap side of the VM conf.

## The pool mount's member model

The appliance carries no bcachefs tools (no `show-super`, no fsck — see
[docs/RECOVERY.md](../../docs/RECOVERY.md) for why that is deliberate), so
member identity cannot be checked in-guest. The guarantee is layered:

1. **host-side**: the supervisor PCI-attaches exactly the two pool disks
   (matched by serial) to slots 3 and 4 → the guest sees `/dev/vdb`,
   `/dev/vdc`;
2. **guest-side** (`pool-up`): both members must exist before any mount; a
   missing member is refused loudly ("member missing — refusing; see
   docs/RECOVERY.md"); a failed mount reports "pool likely needs fsck" —
   never a bare rc 1.

Different slot plan? Override `MEMBERS` in `/etc/conf.d/pool-up` (sourced
automatically by OpenRC).

## Checklist: what must exist inside the built squashfs

- `/pool` and `/proc/fs/nfsd` (created by `build-rootfs.sh`)
- `/etc/init.d/{pool-up,pool-nfs}` + the runlevel symlinks above
- `/etc/exports` with YOUR client
- `/lib/modules/<KVER>/` full tree with `kernel/fs/bcachefs/bcachefs.ko` and
  a depmod-fresh `modules.dep` containing bcachefs plus its **6 leaf
  modules**: `xor`, `raid6_pq`, `libchacha`, `libpoly1305`,
  `lz4_compress`, `lz4hc_compress`
- root: empty password (access plane above)
- `openrc`, `nfs-utils(-openrc)`, `rpcbind(-openrc)` installed

# Build findings: the Alpine appliance, the module recipe, the NFS plane

> English distillation of three Russian build reports —
> [`alpine-spike.ru.md`](alpine-spike.ru.md) (initramfs spike),
> [`v03-step2.ru.md`](v03-step2.ru.md) (kernel module + pool-up),
> [`v03-step4.ru.md`](v03-step4.ru.md) (NFS plane). Same numbers and
> verdicts; private paths and session names stripped. F-numbers are defined
> in [`FINDINGS.md`](FINDINGS.md).

## Result

- **The appliance boots and does its one job**: Alpine 3.23 minirootfs guest
  (`linux-lts` 6.18.62-0-lts), squashfs read-only root, OpenRC; at boot it
  loads the self-built `bcachefs.ko` 1.39.7 and mounts the pool rw
  (`pool-up`), then serves NFS (`pool-nfs`).
- **Full interop proven**: mkfs with Alpine edge tools 1.38 → rw writes by
  the self-built 1.39.7 module → read back by an independent 1.39.7
  (Debian) toolset. Forward-compat mount (1.39.7 module on a 1.38-format
  pool) also proven.
- **Version gate decision**: Alpine edge ships tools 1.38 < 1.39, so Alpine
  is the *recipe* reference (scratch pools self-consistent at 1.38); any
  pool at format 1.39 stays with the Debian-line 1.39.7 stack until edge
  catches up.
- **The NFS rehearsal closed 100%**: boot → pool (2-member rw) → NFS server
  → host mount → write/read roundtrip. Final boot #24, all green.

## Boot matrix (6 iterations, one finding each)

| # | initramfs | verdict | lesson |
|---|---|---|---|
| 1 | FreeBSD cpio, no loader | no init | — |
| 2 | GNU cpio, no loader | no init | busybox is dynamically linked! |
| 3 | GNU cpio + musl loader, 3 modules | **shell on the console** | initramfs alive |
| 4 | FreeBSD cpio + loader + 7 modules | no init | **F12: kernel rejects FreeBSD-cpio newc** |
| 5 | GNU cpio + 7 modules, loader missing from host staging | no init | self-inflicted |
| 6 | GNU cpio + loader + full virtio closure | **login prompt** | ✅ |

Final: `Welcome to Alpine Linux 3.23 / kernel 6.18.62-0-lts / ttyS0 login`.

## Image stack (what actually ships)

- squashfs root: **141 MB** (Alpine minirootfs + OpenRC + the NFS server
  stack) — ×7.7 smaller than the earlier Debian root (1.09 GB).
- initramfs: busybox + `ld-musl-x86_64.so.1` + 7 modules (virtio,
  virtio_ring, virtio_pci + legacy/modern_dev, virtio_blk, squashfs) with a
  canonical `modules.dep`; packed **newc by GNU cpio** (F12).
- UKI: **38 MB**, assembled by `ukify` in the Debian builder — cpio and
  ukify are the only two steps of the pipeline that run in the Linux
  builder; everything else is host-native.
- Alpine's stock kernel builds `SQUASHFS=m VIRTIO_BLK=m` — the initramfs is
  **mandatory** (unlike freebsd-wifibox's custom kernel, where they are `=y`
  and no initramfs is needed).
- `bcachefs.ko.gz` **22.7 MB** + 6 leaf dependency modules (`xor`,
  `raid6_pq`, `libchacha`, `libpoly1305`, `lz4_compress`, `lz4hc_compress` —
  all `=m`) baked into the full `/lib/modules` tree.

## Kernel module recipe (F16)

Build **never from the tarball root** (that path drags in cargo). Stage
Kent's kernel tree from inside the tarball and use his own dkms Makefile —
inside an Alpine chroot whose `linux-lts-dev` headers match the appliance
kernel exactly:

```sh
mkdir -p D/src/fs/bcachefs
tar -C fs -cf - . | tar -C D/src/fs/bcachefs -xf -
cp -a dkms/Makefile D/Makefile
echo '#define bcachefs_version "1.39.7"' > D/src/fs/bcachefs/version.h
cp -a dkms/module-version.c D/src/fs/bcachefs/
env BCACHEFS_DKMS=1 make -C /usr/src/linux-headers-6.18.62-0-lts M=D modules
```

- source tarball: `evilpiepirate.org/bcachefs-tools/bcachefs-tools-1.39.7.tar.zst`
  — pin the version explicitly;
- resulting vermagic: `6.18.62-0-lts SMP preempt mod_unload modversions` —
  must match the appliance kernel exactly;
- Kent's `dkms.conf` sets `BUILD_EXCLUSIVE_KERNEL_MIN=6.16`.

## Build-environment quirks (F18)

Alpine chroot inside a Debian builder:

- `apk` needs an **IPv4 pin in `/etc/hosts`** (musl is IPv6-first; there is
  no v6 route);
- the Alpine mirror URL carries a `/MIRRORS/` path segment, not `/alpine/`;
- `export RM='rm -f'` — it is empty in the kbuild context;
- `musl-dev` + `linux-headers` (UAPI types) + Kent's full pkg-config dev
  set: the module links userspace objects (`libbcachefa.a`-style — the
  kernel build pulls in userspace-built objects);
- `apk --root <dir>` must run *from inside* the chroot with `<dir>` visible
  from inside it (F19); never pipe a builder step through `tail` when you
  assert on its exit code — `set -e` goes blind (F20).

## Scars, condensed (F12–F25)

- **F12** — FreeBSD cpio `-H newc` ≠ kernel-accepted newc; build initramfs
  with GNU cpio. (This is why freebsd-wifibox lives in a Linux toolchain.)
- **F13** — minirootfs busybox is **dynamically linked**: without
  `ld-musl-x86_64.so.1` in the initramfs the boot dies with "No working init
  found" — a message that covers both unpack failure and exec failure.
- **F14** — virtio modules on 6.18 need their **full dependency closure**
  (`virtio_ring`, `virtio_pci` legacy/modern_dev, …); a hand-trimmed
  `modules.dep` with empty deps **silently** fails to bring up the block
  device.
- **F15** — bcachefs was **removed from the Linux mainline between v6.17
  and v6.18** (verified: `fs/bcachefs` absent on peeled v6.18, 260 entries
  on v6.16/6.17). On 6.18+ the module is out-of-tree by necessity; the
  recipe bakes it into the image at build time.
- **F16** — the module recipe above; the tarball root is a cargo trap.
- **F17** — squashfs ro-root: **bake mountpoints into the image** (`mkdir`
  in a read-only `/newroot` fails); the demo workaround was a `/pool-tmp`
  dir in the initramfs.
- **F21** — device identification by **name** kills: a `dd`-wipe guard
  (`grep -q` against the VM conf) matched **commented** lines, so the wipe
  hit the wrong disk (a state disk from an earlier experiment iteration — a
  reproducible artifact, no real data lost). Identify devices by
  **slot + serial**, never by name; assert against *active* config lines
  only. Any `dd`-to-device step in this recipe carries that warning.
- **F22** — `rpcbind` does not survive busybox `start-stop-daemon` (dies
  silently); `supervise-daemon` is ignored in the minirootfs OpenRC. The
  `pool-nfs` unit therefore starts `rpcbind -f -s` itself, in the
  foreground.
- **F23** — `rpc.statd` is unnecessary for NFSv4 (no NSM/NLM) — dropped;
  the v3 path is served by `rpc.mountd`.
- **F24** — **MTU parity host↔guest**: with the tap at 9000 and the guest
  eth0 at 1500, the first NFSv4 connect dies and `mount_nfs` enters an
  infinite reconnect (unkillable zombie) holding the per-server lock —
  every subsequent mount fails EBUSY **without a single packet on the
  wire**. Diagnose with `tcpdump` + `procstat -k`, never by retrying.
- **F25** — false-positive "roundtrip OK": writing + `cat`-ing at an
  **unmounted** mountpoint just writes a local file. Test gate:
  `mount | grep` **before** writing.

## Rehearsal finale (pre-alpha gate)

A 14-boot debug run distilled into the shipped units, ending green: static
eth0 (MTU 9000), OpenRC runlevels (sysinit/boot/default), `pool-up` mounting
a 2-member scratch pool rw, `pool-nfs` self-contained (rpcbind foreground →
exportfs → mountd → nfsd v3/4/4.1/4.2), host-side TCP 2049/111 live, and the
host NFSv4 mount proven with `write → read → ls → umount` (RT-V4-OK). The
pre-MTU `mount_nfs` zombies were a client-side artifact; a host reboot
clears them (F24) — folded into the alpha ceremony instead of left as a
blocker.

Evidence: console logs (`console-alpine-sqfs-boot.log`,
`console-alpine-poolup.log`, `console-appliance-nfs-final.log`) are archived
under `docs/evidence/`.

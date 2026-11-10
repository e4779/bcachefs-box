# FINDINGS — the F-index

Every F-number referenced anywhere in this repo, defined. The numbering is a
running log of scars across the build/run reports (F11–F29). Entries marked
**(reconstructed)** are not defined in any repo document; their wording is
distilled from the upstream evidence archive the build reports point at.

| # | Finding |
|---|---|
| F11 | **(reconstructed)** Read-only-root shakeout: systemd units not prepared for a read-only `/` dropped the boot into emergency, and the emergency target itself was unusable ("root account is locked" — no root password in the image). Recipe: an emergency hook, or an unlocked root in a rescue-only image only. |
| F12 | FreeBSD cpio `-H newc` archives are **not** accepted by the Linux kernel — build initramfs files with **GNU cpio**. |
| F13 | Alpine minirootfs busybox is **dynamically linked** — the initramfs must ship `ld-musl-x86_64.so.1`, or the boot dies with "No working init found" (that message covers unpack failure and exec failure alike). |
| F14 | Virtio modules on 6.18 have a real dependency closure (`virtio_ring`, `virtio_pci` legacy/modern_dev, …) — a hand-trimmed `modules.dep` with empty deps **silently** fails to bring up the block device. |
| F15 | bcachefs was **removed from the Linux mainline between v6.17 and v6.18** — on 6.18+ the module is out-of-tree by necessity, and the image recipe must build it explicitly. |
| F16 | Kernel-module build recipe: never build from the tarball root (it drags in cargo); stage Kent's `fs/bcachefs` subtree with his `dkms/Makefile`, set `version.h`, build with `BCACHEFS_DKMS=1` against the appliance kernel's exact headers. Full recipe: [build-findings.md](build-findings.md). |
| F17 | squashfs read-only root: **bake mountpoints into the image** — `mkdir` in a read-only `/newroot` fails at boot. |
| F18 | Alpine-chroot-in-Debian-builder env quirks: IPv4 pin in `/etc/hosts` (musl is IPv6-first), the `/MIRRORS/alpine` mirror path, `export RM='rm -f'`, `musl-dev` + `linux-headers` + Kent's pkg-config dev set (the module build pulls in userspace objects). |
| F19 | **(reconstructed)** `apk --root <dir>` must be run from inside the chroot, with `<dir>` visible from inside it; a bare-Debian apk has no such mode. |
| F20 | **(reconstructed)** Piping a builder step's output through `tail` swallowed both the error message and the exit code — `set -e` went blind. Don't pipe steps you assert on. |
| F21 | Device identification by **name** kills: a guard `grep -q` matched commented config lines, so a `dd`-wipe hit the wrong disk (a state disk instead of the scratch target; the loss was a reproducible artifact). Identify devices by **slot + serial**; assert against active config lines only. |
| F22 | `rpcbind` dies silently under busybox `start-stop-daemon` (`supervise-daemon` is ignored in minirootfs OpenRC) — start it in the foreground from your own unit (`rpcbind -f -s`). |
| F23 | `rpc.statd` is unnecessary for NFSv4 (no NSM/NLM) — don't ship it; serve the v3 path with `rpc.mountd`. |
| F24 | **MTU parity host↔guest** — a mismatch (tap 9000, guest 1500) kills the first NFSv4 connect and leaves an unkillable `mount_nfs` reconnect zombie holding the per-server lock: all later mounts fail EBUSY with zero packets on the wire. Diagnose with `tcpdump` + `procstat -k`; never diagnose by retrying the mount. |
| F25 | False-positive "roundtrip OK": writing+reading at an **unmounted** mountpoint creates a local file. Gate every test with `mount | grep` before writing. |
| F26 | Quiesce = a **full `service -e` inventory**, not a selective grep; a missed auto-restart watchdog re-raised a FUSE mount on top of the VM's disks → ~4 min dual-writer → unclean shutdown → 7.5 h recovery. Watchdog names don't say what they do; while two stacks can touch the same disks, they need a common mutex. Story: [alpha-run.md](alpha-run.md). |
| F27 | `/tmp` is wiped at reboot (`clear_tmp_enable`) — VM test disks kept in `/tmp` vanish; keep them on zvols. |
| F28 | Before reading a verdict from a console log: **truncate it and verify the boot is fresh** — a stale log from a previous boot reads as a brand-new failure. |
| F29 | An rc variable `NO` does not prove a service can't start: a **separate raiser** (a watchdog with its own while-loop) re-launched the daemon repeatedly (twin processes minutes apart). Check for independent raisers. |

Note: `host/run-bcachefsbox.sh` comments also cite F1/F2 — those belong to an
earlier "phase-0" finding series from the pre-appliance bench stand (nmdm
console echo discipline, boot-chain surgery), not to this index.

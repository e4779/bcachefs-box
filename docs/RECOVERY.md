# RECOVERY — when the pool won't mount, and how to fix it

This is a required part of the recipe, not an anecdote: the appliance ships
**no bcachefs tools and no fsck**, and the FreeBSD host has neither. After an
abnormal event, mount-time repair can exhaust itself — and the only repair
path is a second Linux VM with matching tools. This document describes that
path as a first-class component of the setup.

> Written from a real recovery: 2026-11-09, a 4.4 TB two-member pool
> (NVMe + HDD) after an accidental dual-writer window and an unclean
> power-off. Full incident chain: [alpha-run.md](alpha-run.md); version
> rules: [version-floor.md](version-floor.md); F-numbers:
> [FINDINGS.md](FINDINGS.md).

## 1. What mount-time recovery does, and when it's exhausted

On mount, the kernel replays the journal and runs allocation/topology
consistency checks. The observed exhaustion mode:

- journal replay **succeeds**,
- then `check_alloc_info` fails → **`journal_shutdown`** — the kernel gives
  up on self-repair and shuts the filesystem down,
- the **superblock accumulates recovery-pass flags**, so the next rw mount
  goes into deep passes instead of a normal boot.

At the recipe level the visible symptom is simply `pool-up` failing at the
mount step after an unclean shutdown.

Deep passes are a pass engine: the superblock schedules a named set —
observed: `check_topology`, `check_allocations`, `check_alloc_info`,
`btree_bitmap_gc` (4 scheduled) — and runs it sequentially with full btree
rescans. In the reference incident the engine ultimately executed **6 passes
in ~7.5 h**: a pass that repairs something can send the engine back through
earlier passes (rewinds), and every pass rescans the btree end to end. The
HDD member (3.6 TB) was the bottleneck; the initial estimate was 1.5–3 h —
plan for the estimate to be a lower bound.

Two properties worth knowing before you panic:

- **The pool stays readable during recovery.** In the reference incident the
  data was readable at intermediate stages — enough to copy what matters off
  while the passes run.
- **A clean shutdown clears the flags.** Once passes complete, a *clean*
  unmount/shutdown of whatever mounted rw drops the superblock recovery
  flags; after that the pool mounts instantly (observed: `pool-up [ok]` on
  the first try).

## 2. Wait vs fsck: the decision rule

**Wait — let the kernel's pass engine work — when:**

- the mount entered deep passes and dmesg shows forward progress (pass
  names, percentages, scan position moving);
- data is readable in the gaps (pre-copy critical data while it runs);
- no new recovery flags appear after an interruption.

**Run userspace `fsck -y` when:**

- the mount cycle repeats the same failure (`check_alloc_info` →
  `journal_shutdown`) with no pass progress;
- passes stall or restart without net progress across an observation window;
- you need the pool back in a bounded window and the rescue VM is ready.

Hard rules while recovery is in flight:

- **Never power-cycle mid-pass.** The next mount resumes from the
  superblock's recovery flags — you restart the pass engine, not continue it;
  interruptions only grow the work.
- **Never allow two writers.** One stack, one rw mount. The reference
  incident *started* as a dual-writer window (F26); repairing a pool while a
  second consumer still holds it doubles the damage and the hours.
- **Verify the quiesce first**: a full `service -e` inventory, no FUSE
  mounts, no other VM holds the disks (F26, F29).

## 3. The rescue VM (the "second Linux VM" pattern)

Prerequisite, prepared **before** you need it: a small warm-standby Linux VM
on the same host — the *reference VM* — whose only job is to carry a
**kernel module + userspace tools from the same pin as the pool**, built
from Kent's tree (floor and skew rules: [version-floor.md](version-floor.md)).
In the reference setup it is a Debian guest with a DKMS module and matching
tools. The appliance can't do this job (no tools inside), and the FreeBSD
host can't (no bcachefs at all). If a future image ships tools ≥ 1.39 in the
guest, steps 3–4 can run in-guest; the second-VM pattern remains the
fallback for images without tools.

Procedure:

1. **Stop every writer.** Appliance VM powered off, FUSE stack off,
   consumers off. Verify nothing holds the disk devices (on FreeBSD:
   `fstat` against the devices; inside the appliance: nothing mounted).
2. **Present the pool members to the rescue VM** (the passthrough slots for
   the member devices) and boot it. Confirm the module version:
   `cat /sys/module/bcachefs/version` — it must be ≥ the pool's on-disk
   format (the rescue stack is the compatibility ceiling).
3. **Triage read-only first**: `bcachefs fsck <members>` (no `-y`) — see
   what the damage is before repairing. If the pool still mounts rw cleanly,
   this check is the whole treatment.
4. **Repair**: `bcachefs fsck -y <members>` — userspace fsck, offline,
   against the member devices as they appear inside the rescue VM. This is
   the tool the whole rescue VM exists for. Expect **hours, not minutes** on
   a multi-TB pool with an HDD member — the same order as the mount-time
   passes (reference: ~7.5 h for ~2.7 TB of data with a 3.6 TB HDD member).
5. **Clear the flags cleanly**: when fsck/repair finishes, do a **clean**
   shutdown of the rescue VM — never force-off — so the superblock recovery
   flags are dropped.
6. **Hand back**: power the appliance on; `pool-up` should mount instantly
   (observed in the reference incident). Spot-check the data, then re-enable
   consumers one at a time.

## 4. Prevention (cheaper than recovery)

- **Single-writer guard**: while two stacks (a host-side FUSE line and the
  VM line) can see the pool disks, a common mutex is mandatory — a FUSE-era
  watchdog must check whether the VM stack owns the disks before raising
  anything (F26).
- **Quiesce discipline**: full `service -e` inventory before any maintenance
  window; rc `NO` doesn't prove a service can't come back — look for
  independent raisers (F29).
- **Clean shutdowns only**: ACPI shutdown plus a verified unmount; treat any
  force-off as the start of the recovery clock.
- **Version floor**: every stack near the pool ≥ 1.39 (drain fix + format
  gate); never point older tools at a ratcheted pool —
  [version-floor.md](version-floor.md).
- **Fingerprint the superblock** (`bcachefs show-super`) before and after the
  first mount by any new stack: even a ro mount may replay the journal.

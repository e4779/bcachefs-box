# Why the version floor: the reconcile/copygc drain deadlock

> English distillation of [`version-floor.ru.md`](version-floor.ru.md)
> (originally an internal investigation transcript; what survived
> sanitization is the bug → fix → version chain below). This page justifies
> the README *Version policy* floor of 1.39.

## The bug: the writeback queue stops draining

bcachefs can reach a state where the writeback/reconcile pipeline stops
flushing to disk — the queue never drains. On a tiered pool (NVMe foreground
+ HDD background) the signature, read from `/sys/fs/bcachefs` metrics:

- `copygc_waiting_for_bytes` stuck non-zero,
- `reconcile_blocked`,
- `reconcile_target_pending_bytes` growing,
- writeback emitting `Leaving` with no progress behind it.

## The incident (August 2026)

On a production pool running **1.38.8** (tiered NVMe fast + HDD cold),
contention between reconcile and copygc produced a **full reconcile
deadlock**: work stuck in `blk_mq_get_tag` with the NVMe tier full —
**~1 TB of writeback backlog sat undrained for a week**.

A second chronic symptom on the same pool: stale generations blocked the
discard worker (`bad_data_type` seen at 100%, `discarded: 0`) — 2026-08-09:
600 GB of deletions never trimmed; 2026-09-06: 18.6M stuck buckets.

## The fix: 1.39.0 — `per_dev_fragmentation_lru`

From the 1.39.0 release notes:

> fragmentation LRU used by copygc is now per device instead of filesystem
> wide. This solves long standing contention issues between reconcile and
> copygc, particularly with tiered setups

## Verified in practice: 1.39.4

Pool upgraded 1.38.8 → 1.39.4 on 2026-09-06 (DKMS packages from Kent's
`apt.bcachefs.org` repository against the Debian kernel):

- minutes after the remount the queue began draining (writeback `Leaving`
  203 → 166 GB in ~4 min);
- the backlog fully drained in ~15 h: **190 GB → 537 MB**, `bad_data_type`
  = 0.

## The chain to 1.39.7

2026-11-03..04: the reference Debian VM (the warm-standby/rescue stack) was
upgraded to **1.39.7** — DKMS kernel module + userspace tools built from
Kent's repository (`apt.bcachefs.org`). 1.39.7 > 1.39.0, so it carries the
drain fix. This hardened into the standing directive:

> Build the module for every stack from Kent's source tree, one tree for all
> lines; the version is a deliberate pin **above the drain fix** (floor 1.39).

(Honesty note: an earlier internal note claimed the drain bug was hit *on*
1.39.7. A re-investigation found no written trace of any November drain
incident; all written evidence points to the August deadlock on 1.38.8 with
the fix in 1.39.0.)

## Convergence: the drain fix IS the on-disk format gate

`per_dev_fragmentation_lru` is exactly the feature that gates the **1.39
on-disk format** — the pool ratcheted to format 1.39 at the 1.38.8 → 1.39.4
upgrade. So the floor for any stack allowed near this pool is one and the
same number:

**1.38.8** (August 2026: deadlock, queue not draining, 1 TB/week) →
**1.39.0** = drain fix = format gate (`per_dev_fragmentation_lru`) →
**1.39.4** (2026-09-06: verified in practice, 190 GB → 537 MB / 15 h) →
**1.39.7** (2026-11-04, reference VM, Kent's tree) → directive: own builds
from Kent's tree for every stack, pinned above the drain fix.

## Version skew: which direction hurts

The alpha run deliberately (and successfully) mixed versions: **module 1.39.7
with tools 1.38**. That asymmetry is the survivable direction; the opposite
is the ratchet:

- **Module newer than tools — survivable.** The kernel module negotiates the
  format at mount and mounts pools created by older tools (demonstrated: the
  1.39.7 module mounting a 1.38-format pool forward-compat). But the *first
  rw mount by the newer module ratchets the on-disk format* — after that the
  old tools can no longer fsck the pool. **Mount works; repair doesn't.**
- **Tools (or any stack) newer than the module — the ratchet direction.**
  A rw mount by version N bumps the format to N and cuts off every older
  stack. Even a ro mount may replay the journal: fingerprint the superblock
  (`bcachefs show-super`) before and after the first mount by any new stack.
- **Never point older tools at a ratcheted pool.** Corollaries: pin module
  and tools to the same version from the same tree; the rescue stack's
  version is the pool's compatibility ceiling, and the appliance module pin
  must never exceed it; on-disk format = the max version that ever mounted
  rw.

## Recurrence kit (pre-1.39 stacks only)

For pools still below the fix: rw → ro → rw remount resets the allocator
(`device set-state`), then `trigger_gc` + `trigger_discards` kick the stalled
workers. These are band-aids; the architectural cure is the 1.39 floor.

See also: [RECOVERY.md](RECOVERY.md) (what to do when a pool *does* need
repair), [FINDINGS.md](FINDINGS.md).

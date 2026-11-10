# Alpha run: cutover of the production pool from the FUSE stack to the VM appliance (2026-11-09)

**Status: CONCLUDED — full success (final, 2026-11-10 00:40).** The pool came
out of mount-time recovery, the appliance mounted it instantly, and the whole
chain (consumers → NFSv4 → VM appliance → pool disks) served real data.
Verdict: the VM appliance is viable as a production stack for the pool.

> English distillation of [`alpha-run.ru.md`](alpha-run.ru.md) — same facts,
> numbers and verdict; internal tool names and host identities stripped.
> The recovery this run exercised is documented as a first-class procedure in
> [`RECOVERY.md`](RECOVERY.md); F-numbers are defined in
> [`FINDINGS.md`](FINDINGS.md).

## The cutover ceremony

| # | Step | Result |
|---|---|---|
| 1 | **Quiesce the host**: consumers stopped and removed from autostart (p2p daemons, media server, database; the FUSE mount service and its watchdogs; `fusefs.ko` out of `kld_list`); boot-environment snapshot; clean host reboot | ✅ |
| 2 | **Control roundtrip**: NFSv4 read/write on the scratch pools after cold start (named attributes, 0.1 ms) | ✅ |
| 3 | **Baseline on the reference Debian VM** (warm-standby guest carrying the DKMS 1.39.7 module + tools): pool mounted rw on the production disks — ~2.7 TB of data on the 4.4 TB pool, library intact, NFS read from the host OK | ✅ |
| 4 | **Swap to the appliance** (squashfs guest) over the production disks | ⏸ **incident** (below); pool went into recovery |

## The incident: 4 minutes of dual-writer, then an unclean shutdown

- **16:03** — the reference Debian VM brought the pool up rw (baseline). At
  the same moment a **pool watchdog from the parallel FUSE-era stack** — a
  while-loop whose "first aid" is re-launching the FUSE mount daemon whenever
  it finds it dead, unaware that a VM stack now owns the disks — raised a
  **FUSE mount on top of the VM's passthrough disks**: ~4 minutes of
  dual-writer rw from two independent bcachefs implementations (the 1.39.7
  kernel module and the Rust FUSE port).
- **16:07** — the reference VM was force-powered-off (unclean).
- **16:11** — the appliance mounted the pool: journal replay OK, but
  `check_alloc_info` failed → `journal_shutdown` — **mount-time self-repair
  exhausted** ([RECOVERY.md](RECOVERY.md)).
- **16:22** — the reference VM was raised again: going read-write on the 29th
  minute; the superblock carried flags scheduling **4 deep passes**
  (`check_topology`, `check_allocations`, `check_alloc_info`,
  `btree_bitmap_gc`) — a sequential run with full btree rescans. ETA 1.5–3 h
  (the 3.6 TB HDD member is the bottleneck).

## Why it happened (F26–F29)

- **F26** — the quiesce inventory stopped the FUSE mount service and one
  watchdog but missed the auto-restart watchdog next to it in the rc list:
  read with the eyes instead of enumerating. Quiesce = a **full `service -e`
  inventory**, not a selective grep; watchdog names don't announce what they
  do.
- **Architecture collision**: two stacks (FUSE on the host, VM appliance)
  claimed the same pool disks; the watchdog of one stack knew nothing about
  the other. While both exist, a **common mutex is required** (e.g. the
  watchdog checks whether the VM stack is enabled before raising anything).
- **F27** — `/tmp` is wiped at reboot (`clear_tmp_enable`); VM test disks
  kept in `/tmp` vanish (supervisor FATAL, VM "didn't start"). Keep test
  disks on zvols.
- **F28** — the operator chased a phantom failure by reading a **stale
  console log** from a previous boot. Before reading a verdict from a log:
  truncate it and verify the boot is fresh.
- **F29** — the morning "the FUSE mount is back" was the watchdog re-raising
  the daemon all along (twin daemons minutes apart — its own loop). The rc
  variable was honestly `NO` — the raiser lived in a separate service. `NO`
  in rc.conf does not prove a service can't come up: check for independent
  raisers.

## Decision tree after the mount verdict

- **MOUNTED** → `bcachefs fsck` with the reference VM's tools → data
  spot-check → continue alpha step 4 (appliance swap) → consumers back one
  at a time.
- **FAILED** → userspace `bcachefs fsck -y` from the reference VM — the whole
  reason it exists. See [RECOVERY.md](RECOVERY.md).

## Final numbers (2026-11-10, 00:40)

- Recovery completed: **6 passes, ~7.5 h total**; damage from the 4-minute
  dual-writer window = **2 checksum errors on the HDD member**; write errors
  0; the library was readable at intermediate stages.
- A clean shutdown of the reference VM cleared the superblock recovery flags.
- **Appliance + production pool: mounted instantly** (`pool-up [ok]`,
  `nfsd [ok]`).
- Host side: NFSv4 + `nconnect=4` to the library; spot read **158 MB/s**
  single-stream (3 MiB in 0.0198 s), zero errors.
- **Verdict: the VM appliance is viable as the production stack for this
  pool.** Remaining alpha work at that point: migrate consumers back one by
  one, then a soak in the next window.

## Aftermath

The experiment concluded viable. Production subsequently moved to the
bcachefs FUSE-port route on the host; the appliance stack documented in this
repo remains a proven fallback/DR path and a benchmark platform (see README,
Status).

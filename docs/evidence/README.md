# Evidence artifacts (2026-11 alpha run)

Committed, sanitized captures backing the "Proven on real hardware" table
in the top-level README. Provenance: the private evidence directory of the
2026-11-08 night bench run; nothing here has been re-measured or edited
beyond the sanitization pass described at the bottom.

## soak-metrics.tsv

Host-side trail appended every 10 minutes during the overnight soak, by a
small sampling loop (the loop itself is not committed). Columns:

- `HH:MM` — time of day on the capture host; **the date is not recorded
  in the file**
- `ld=` — host 1-minute load average (`uptime`)
- `nfs_err_delta=` — per-sample delta of the NFS client
  timeout/retransmit/credential-failure counters (`nfsstat -c`); `0` in
  every committed sample means no timeouts and no retransmits
- `nfs_req_total=` — cumulative NFS client RPC count (same source)
- `consumers=` — number of active `/mnt/pool` mounts followed by
  anonymized single-letter flags for running consumers; `1SAQN` reads as
  "1 mount, 4 consumer flags up"

Known imperfections, stated plainly: time-of-day only; one 7.5 h sampler
gap (02:03→09:33) whose cause is not recorded — the RPC counter continues
monotonically across the gap, so no client reset/reboot happened between
the two segments.

## console-alpine-poolup.log

Serial-console capture spanning several VM boots of the pool-up rehearsal
(~15k lines, ANSI escapes included, committed verbatim). It contains:

- the sealed-image boot to login;
- the version forward-compat mount proof: module 1.39.7
  (`per_dev_fragmentation_lru`, format 1.39) mounting a 1.38-format
  scratch pool — `starting version need_discard_by_journal_seq (1.38)` →
  `Doing compatible version upgrade ... to per_dev_fragmentation_lru
  (1.39)` → `POOL-UP: OK`;
- the NFS service plane coming up (exportfs / mountd / nfsd);
- heartbeat-writer units from an **earlier, systemd-based rootfs
  iteration** — the shipped OpenRC appliance does not include a
  heartbeat (README, Status/roadmap).

This is a rehearsal capture (scratch pool); it is not the alpha stand's
2-member mount.

## console-alpine-sqfs-boot.log

Serial-console capture of the squashfs appliance boot (Alpine): sealed
image → login prompt over the serial console.

## Deliberately not committed

- `console-appliance-nfs-final.log` — named as the V0.3 STEP 4 artifact
  in the upstream run report, but the file was not preserved; nothing
  here stands in for it.
- the fio/dd transcripts behind docs/bridge-comparison.md — only the
  summary tables survive, in that report.

## Sanitization statement

All three files were grepped for LAN/private IPv4 addresses, MAC
addresses, hostnames, SSH host keys/fingerprints, disk serials (NVMe/ATA
identify output), session UUIDs and private tool paths: zero matches.
(The only regex hit is the kernel's benign `Serial: 8250/16550 driver`
dmesg line.) The guest hostname visible in the captures is the
appliance's own static name, `bcachefsbox`. No IPv4 address appears in
either console capture.

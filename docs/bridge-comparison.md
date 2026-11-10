# Bridge comparison: NFSv4 vs 9p vs sshfs

When a bcachefs pool lives inside a VM and the host consumes it, the
guest→host file bridge is a design decision worth measuring. In October 2026
three candidates were compared on stands that mirrored the target topology
(tiered bcachefs pool in a Linux VM, FreeBSD/Linux hosts consuming it).
This document is the adapted decision record.

## What was compared

| Candidate | Role in the test |
|---|---|
| **kernel NFSv4** (nfsd in the guest) | the primary candidate for the data path |
| **9p** (diod server + Linux v9fs client; FreeBSD p9fs researched in source) | the lightweight-protocol candidate |
| **sshfs** | the baseline |

## Stand design (essentials)

- qemu-kvm first (transparency), then the final mini-stand on bhyve with the
  production topology: FreeBSD host → bhyve → Linux VM, bcachefs pool on
  raw virtio disks, NFS over a native virtio-net bridge (no slirp).
- Tiered pool: NVMe foreground + HDD background — the question was whether
  the hot tier survives the bridge.
- fio matrix: seq-read 1M QD32, seq-write, rand-4k QD1, fsync, smallfiles
  (create/delete storms), tar-extract; 3 runs, median, caches dropped.

## Results

### Throughput and latency (through the full bridge)

| Measurement | NFSv4 | Notes |
|---|---|---|
| seq read, native virtio bridge | **570 MB/s** (dd 1 GiB, cold; MTU 9000) | guest-local reference 134 MB/s on that stand; ~85% of guest-local on the saturated-stand run (494–505 MiB/s vs 593–602) |
| seq read, MTU 1500 | 134 MB/s | **MTU is the biggest single lever** — 4.3× from jumbo frames |
| seq write | ~145 MB/s (189–218 on the qemu stand) | the NFS commit tax; sufficient for a seeding profile |
| 4k QD1 latency | guest 1.2 ms → bridge 1.75 ms | +0.55 ms bridge tax under host CPU saturation |
| smallfiles, sync create | 12.8 ms/file | calibratable with async exports |

### 9p, measured where it could run

| Measurement | 9p | Notes |
|---|---|---|
| seq read (diod on local storage, Linux client, msize=128K) | **312–486 MB/s** (cache=loose 362) | protocol-cost isolation, not the full bridge; provenance caveat applies |
| smallfiles 2000 (in-VM bridge measurement) | **1.9 s vs 25 s NFS** | **13× metadata advantage** |
| writes | worked only in the write-side redo | see the transport fate below |

### The deciding factor: transport availability, not speed

The FreeBSD 9p client (`p9fs`) has exactly one transport: **virtio**
(`p9_register_trans` registry, single registrant `sys/dev/virtio/p9fs/`).
There is no network client — so the guest→host direction this design needed
could not be assembled from stock FreeBSD parts, while NFS needed zero new
code. Two upgrade paths were noted and parked: a TCP `p9_trans_module`
for upstream, or a self-hosted 9P2000.L server (13× metadata carrot).

The 13× metadata win matters for metadata-heavy workloads; for a storage
bridge whose hot path is large-file streaming, it was not worth new code.

## Mount recipe that fell out of the benchmarks

- **MTU 9000** across the bridge (host tap + guest NIC) — 4.3× on reads;
- **`nconnect=4,readahead=8`** — compensates the 64K rsize ceiling and
  request serialization;
- on multi-homed hosts, **pin the route** (`route add -host <srv> -iface <if>`)
  — one wired run silently went over WiFi and produced a false "the FreeBSD
  NFS client is slow" conclusion. After pinning: 84 MB/s even through a
  slirp tunnel — full client parity with Linux.

## Retrospective cross-check (Nov 2026 appliance run)

The appliance stack measured 158 MB/s single-stream read end-to-end with
zero NFS errors over an 8-hour soak — consistent with the bridge
predictions once MTU parity was enforced (see README, F24).

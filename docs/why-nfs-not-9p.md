# Why NFSv4 and not 9p/virtio-p9fs

When the bridge between a bcachefs VM and a FreeBSD host was designed
(Oct 2026), three candidates were measured on real stands: kernel NFSv4,
9p (diod + Linux v9fs client / FreeBSD p9fs research), and sshfs as the
baseline. This is the recovered decision record.

## The numbers

| Metric | NFSv4 (kernel nfsd) | 9p | sshfs |
|---|---|---|---|
| Seq read, native virtio-net bridge | **570 MB/s** (dd 1 GiB cold; guest-local reference 134) | 312–486 MB/s (diod server, `msize=128K`; cache=loose — 362) | far below both |
| Seq write | ~145 MB/s (NFS commit tax) | — | — |
| Metadata storm (smallfiles, 2000 files) | **25 s** | **1.9 s — 13× faster** | — |

9p read provenance caveat: the read series was measured with diod on the
host against local storage (protocol cost isolation), not through the full
bcachefs-in-VM bridge; the 1.9 s smallfiles number is a real in-VM bridge
measurement.

## Why NFS won anyway: transport fate, not speed

The FreeBSD 9p client (`p9fs`) has **exactly one transport: virtio**
(`p9_register_trans` registry, single registrant
`sys/dev/virtio/p9fs/virtio_p9fs.c`). There is no network client, so the
guest→host bridge direction the design needed could not be assembled from
stock parts. NFS needed zero new code.

The 13× metadata win stayed on the shelf as a parked idea with two paths:

- write a TCP `p9_trans_module` for upstream FreeBSD (sample driver:
  virtio_p9fs.c);
- or run our own 9P2000.L server (wikifs-on-Rust experience exists).

Neither was worth it for a storage bridge whose hot path is large-file
streaming — exactly NFS's strength and 9p's non-win.

## The NFS recipe that fell out of the benchmarks

- **MTU 9000** on the bridge (host tap + guest NIC) — the single biggest lever;
- mount with **`nconnect=4,readahead=8`** — compensates the server's
  64K rsize ceiling and the serialized request pipeline;
- on a multi-homed host, **pin the route** (`route add -host <srv> -iface <if>`)
  — one "wired" benchmark run silently went over WiFi and cost a false
  "FreeBSD NFS client is slow" conclusion. After pinning: 84 MB/s through
  even a slirp tunnel — full parity with the Linux client.

## Retrospective cross-check (Nov 2026 appliance run)

The appliance stack measured 158 MB/s single-stream read end-to-end with
zero NFS errors over an 8-hour soak — consistent with the bridge
predictions once the MTU parity lesson (see README, F24) was applied.
